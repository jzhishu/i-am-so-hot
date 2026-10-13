import Foundation

/// 监控编排器（技术方案 §2 / §7）：
///
/// 单一调度入口，每次 tick：
/// 1. 读取廉价指标（Total CPU / 温度 / thermalState）
/// 2. 更新采样模式（SLEEP / WATCH / LIVE）
/// 3. idle 时学习 Baseline
/// 4. WATCH / LIVE 下做详细进程采集 → 归属 → 聚合 → 热模型
/// 5. 产出 MonitorSnapshot 供 UI 消费
///
/// 设计约束：
/// - 只在主调用线程使用（非线程安全），由 App 层负责调度与节流。
/// - SLEEP 模式不做 per-process 采集（§6.1），但热水库继续衰减，
///   保证"App 停止后热贡献缓慢消失"的语义成立。
public final class ThermalMonitor {

    private let temperatureProvider: TemperatureProvider
    private let cpuSampler = CPUSampler()
    /// GPU 采样器（v0.5）：每个 tick 枚举一次累计值——
    /// Monitor 自 diff 得设备级 busy 总量（SLEEP 回填 / w_g 标定）；
    /// 详细 tick 把累计值交给 ProcessCollector 按详细间隔做 per-process 差分
    /// （与 CPU 差分同节奏，避免 reseed tick 的归一化口径错配）。
    private let gpuSampler = GPUSampler()
    /// 上一 tick 的累计 GPU 时间（busy 总量差分基准）
    private var previousTickGPU: [pid_t: UInt64] = [:]
    private let collector = ProcessCollector()
    private let resolver = AppResolver()
    private var engine: ThermalEngine
    private var baseline: BaselineTracker
    private var modeController = SamplingModeController()

    /// Popover 打开状态（LIVE 触发条件），由 App 层设置。
    public var isPanelOpen = false

    /// 本进程 PID：自身不参与热源排名
    /// （原则：I AM SO HOT 不应出现在 Top Heat Contributor 前列）。
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var appsByID: [String: AppIdentity] = [
        AppIdentity.macOS.id: .macOS,
        AppIdentity.other.id: .other,
    ]

    /// 上次详细采样时间（CPU 差分口径）
    private var lastDetailedTick: Date?
    /// 上次 tick 时间（水库衰减口径）
    private var lastTick: Date?
    /// SLEEP 期间保留最近一次详细结果，避免打开面板瞬间空白
    private var lastAppSamples: [String: AppSample] = [:]
    /// SLEEP 连续 tick 数（重播种计时）
    private var sleepTickCount = 0
    /// SLEEP 下每 N 个 tick 做一次详细采样刷新 share 分布。
    /// 8s × 4 ≈ 32s：一次采集约几毫秒 CPU，占空比 ~0.03%，远低于预算，
    /// 换来分布新鲜度——回填是分布不动点，不刷新就会把「进入 SLEEP 那一刻
    /// 热的 App」永久养在水库里（热贡献不衰退，违反热记忆语义）。
    private let sleepReseedInterval = 4
    /// share 分布是否已建立。首次详细采样所有进程 CPU 差分为 0（无历史基准），
    /// 必须采到第二帧才有有效分布，因此播种是一个过程而不是一次采样。
    private var distributionSeeded = false
    /// 逻辑核数（SLEEP 回填时把 0~1 总 CPU 换算为核数口径功率）
    private let coreCount = ProcessInfo.processInfo.processorCount

    /// GPU 功率权重 w_g（技术方案 §8：P_i = w_c·C_i + w_g·G_i，w_c = 1）。
    /// 物理含义：GPU 全部执行单元满载 1 秒 ≈ w_g 个 CPU 核满载 1 秒的发热。
    /// 在线标定（v0.5 Device Calibration）：DevicePowerMeter 设备级功耗实测推导，
    /// EMA 收敛（GPUWeightCalibrator）；IOReport 不可用时保持初值。
    /// 初值 = 0.5 × 核数（经验估计）。实测参考（2026-10-09，M2 Pro）：
    /// 收敛值 ≈ 9.4 ≈ 0.78 × 核数（GPU 满载 ~13.5W / CPU ~1.44W 每核）。
    public var gpuWeight: Double { gpuWeightCalibrator.weight }
    private var gpuWeightCalibrator: GPUWeightCalibrator
    /// 设备级功耗计（IOReport Energy Model），用于 w_g 标定；不可用时为 nil
    private let powerMeter: DevicePowerMeter?
    /// 最近一次设备级功耗读数（DEBUG CSV 观测用）
    public private(set) var lastPowerReading: DevicePowerMeter.PowerReading?

    /// 温度历史（v0.5，§18）：三级降采样，内存常驻。
    /// 持久化由 App 层低频批量处理（historySnapshot / init 注入）。
    private var history: TemperatureHistory

    /// 进行中的降温预测（v0.8）：Quit 时捕获，预测周期结束后自动清除。
    /// 同时只跟踪最近一次 Quit（连续 Quit 时新会话覆盖旧会话）。
    private var activeForecast: CoolingPrediction?
    /// 最近 tick 的实测温度与采样时间（Quit 时刻预测起点用）
    private var lastTemperatureCelsius: Double?
    private var lastTemperatureTime: Date?
    /// 麦克风采集枚举（能耗对账归因增强：语音/视频通话 App 识别）
    private var audioSampler = AudioInputSampler()
    /// 摄像头状态检测（缺口归因的上下文标注）
    private let cameraSampler = CameraStateSampler()
    /// 最近一次 tick 的硬件缺口（核数当量，DEBUG CSV 观测用）
    public private(set) var lastHardwareGapCores: Double = 0
    /// 最近一次缺口 tick 的摄像头采集状态（DEBUG CSV 观测用）
    public private(set) var lastCameraActive = false

    public var currentMode: SamplingMode { modeController.mode }

    /// 温升系数 g（°C / 单位热储量）——热模型 v2 §12.1。
    /// 初值 0.016：2026-09-30 用本机 4 核压测 CSV 离线拟合（范围 0.011–0.020）。
    /// 第三步在线校准（§14）：RLS 回归（实测温度 − 模型baseline）≈ g × ΣH，
    /// 校准值由 GainCalibrator 维护，App 层负责持久化。
    public var thermalGain: Double { calibrator.gain }
    private var calibrator: GainCalibrator

    public init(
        temperatureProvider: TemperatureProvider = IOHIDTemperatureProvider(),
        tauFast: Double = 15,
        tauSlow: Double = 120,
        initialBaseline: Double = 45,
        initialGain: Double = 0.016,
        initialGPUWeight: Double? = nil,
        restoredHistory: TemperatureHistory.Persisted? = nil
    ) {
        let defaultWeight = 0.5 * Double(ProcessInfo.processInfo.processorCount)
        self.gpuWeightCalibrator = GPUWeightCalibrator(initial: initialGPUWeight ?? defaultWeight)
        self.powerMeter = DevicePowerMeter()
        self.history = restoredHistory.map { TemperatureHistory(restoring: $0) } ?? TemperatureHistory()
        self.temperatureProvider = temperatureProvider
        self.engine = ThermalEngine(tauFast: tauFast, tauSlow: tauSlow)
        self.baseline = BaselineTracker(initial: initialBaseline)
        // 恢复持久化的校准值时给予较小初始方差（信任历史校准）
        self.calibrator = GainCalibrator(
            initial: initialGain,
            variance: initialGain == 0.016 ? 1e-4 : 1e-6
        )
    }

    // MARK: - Cooling Forecast（v0.8）

    /// Quit 成功后调用：捕获该 App 的分层热储量 + 当前 g + 当前温度，
    /// 建立降温预测会话。
    ///
    /// 门槛（与面板 what-if 的 ≥0.5°C 显示阈值对齐，review P1）：
    /// - 水库无热量或稳态降幅 < 0.5°C：降幅太小，建立会话只会过度承诺
    /// - 温度未知或过期（超过 2 个采样间隔）：预测起点不可靠
    ///
    /// 线程约定：必须与 tick 在同一执行上下文串行调用
    ///（当前由 @MainActor 的 MonitorService 保证）。
    public func beginCoolingForecast(appID: String, appName: String, at now: Date = Date()) {
        guard let layers = engine.reservoirLayers(for: appID),
              let temp = lastTemperatureCelsius,
              let tempTime = lastTemperatureTime,
              now.timeIntervalSince(tempTime) <= currentMode.interval * 2 else { return }
        let prediction = CoolingPrediction(
            appName: appName,
            fastHeat: layers.fast, slowHeat: layers.slow,
            gain: calibrator.gain,
            tauFast: engine.tauFast, tauSlow: engine.tauSlow,
            startCelsius: temp, startTime: now
        )
        guard prediction.steadyDrop >= 0.5 else { return }
        activeForecast = prediction
    }

    /// 历史持久化快照（App 层低频批量写盘用）
    public var historySnapshot: TemperatureHistory.Persisted { history.export() }

    /// 麦克风采集中的可归因 App（bundleID 口径）。
    /// 只归因到已注册身份的普通 App（保证热榜显示名正常），
    /// 系统/守护进程采集（Siri 等）与未注册身份返回 nil，缺口落 System Hardware。
    private func micActiveAppID() -> String? {
        guard audioSampler.isAvailable else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for pid in audioSampler.activeInputPIDs() {
            guard pid != ownPID else { continue }   // 自己不背锅
            let ownership = resolver.resolve(Self.minimalSample(for: pid), allSamples: [:])
            let appID = ownership.appID
            guard appID != AppIdentity.macOS.id, appID != AppIdentity.other.id,
                  appsByID[appID] != nil else { continue }
            return appID
        }
        return nil
    }

    /// 仅有 pid 时的最小样本（proc_pidpath 对异用户进程也可读）
    private static func minimalSample(for pid: pid_t) -> ProcessSample {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buf, UInt32(MAXPATHLEN))
        let path = len > 0
            ? String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
        return ProcessSample(
            pid: pid, parentPid: 0, executablePath: path,
            processName: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid\(pid)",
            cpuTimeDelta: 0
        )
    }

    /// 能耗对账（纯函数，便于单测）：实测 CPU 封装瓦数超出进程归因的部分，
    /// 折算为核数当量注入 System Hardware 桶。
    /// < 1W 视为测量噪声（防抖），不注入。
    static func hardwareGapCores(
        cpuWatts: Double,
        attributedCores: Double,
        wattsPerCore: Double
    ) -> Double {
        guard wattsPerCore > 0 else { return 0 }
        let gap = cpuWatts - GPUWeightCalibrator.idleWattsFloor - attributedCores * wattsPerCore
        guard gap > 1.0 else { return 0 }
        return gap / wattsPerCore
    }

    /// SLEEP 模式水库回填（纯函数，便于单测）：
    /// 把全机总功率（totalCPU × 核数 + w_g × GPU busy）按上次已知的 share 分布拆分。
    /// share < 1% 的微小 App 不续命（让其自然衰减蒸发，避免长尾被回填永养）。
    /// 过滤后归一化，保证 ΣH 仍朝 P×τ 稳态收敛。
    /// 分布失效（水库为空）时返回空，不产生臆造数据。
    static func sleepRefillScores(
        totalCPU: Double,
        coreCount: Int,
        totalGPU: Double = 0,
        gpuWeight: Double = 0,
        shares: [String: Double]
    ) -> [String: Double] {
        guard coreCount > 0, !shares.isEmpty else { return [:] }
        let totalPower = totalCPU * Double(coreCount) + totalGPU * gpuWeight
        guard totalPower > 0 else { return [:] }
        let significant = shares.filter { $0.value >= 0.01 }
        guard !significant.isEmpty else { return [:] }
        let sum = significant.values.reduce(0, +)
        return significant.mapValues { $0 / sum * totalPower }
    }

    /// 注入 App 注册表（App 启动/退出事件时调用，并清空归属缓存）。
    public func updateAppRegistry(_ apps: [AppIdentity]) {
        appsByID = Dictionary(
            apps.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        appsByID[AppIdentity.macOS.id] = .macOS
        appsByID[AppIdentity.other.id] = .other
        appsByID[AppIdentity.systemHardware.id] = .systemHardware
        resolver.updateRegistry(apps)
        resolver.invalidateCache()
    }

    @discardableResult
    public func tick(now: Date = Date()) -> MonitorSnapshot {
        // ── 1. 廉价指标 ─────────────────────────────────────────────
        let totalCPU = cpuSampler.totalCPU() ?? 0
        // GPU 每 tick 枚举（实测 0.47ms）：差分节奏见上方 gpuSampler 注释
        let gpuCumulative = gpuSampler.cumulativeGPUTimes()
        let reading = temperatureProvider.read()
        let temperature = reading.dieCelsius
        let thermalElevated = ProcessInfo.processInfo.thermalState != .nominal

        // 温度历史（§18）：每 tick 一点，内存成本可忽略
        if let temperature {
            history.record(temperature, at: now)
            lastTemperatureCelsius = temperature
            lastTemperatureTime = now
        }

        // ── 2. 采样模式 ─────────────────────────────────────────────
        modeController.update(
            panelOpen: isPanelOpen,
            totalCPU: totalCPU,
            thermalStateElevated: thermalElevated,
            currentCelsius: temperature,
            baselineCelsius: baseline.baseline
        )

        // ── 3. Baseline（热模型 v2：慢层锚点 + 不对称跟踪，§11）────────
        // 学习 δ 时扣除当前 App 热贡献（上一 tick 的水库状态），
        // 避免常驻负载被同时算进 baseline 和 +°C（双重计算，§12.2 自检等式）
        let appsDeltaC = engine.estimatedDeltaCs(gain: thermalGain).values.reduce(0, +)
        let isIdle = totalCPU < 0.10 && !thermalElevated
        baseline.update(
            die: temperature,
            slowAnchor: reading.slowAnchorCelsius,
            appsDeltaC: appsDeltaC,
            isIdle: isIdle,
            now: now
        )

        // ── 4. 详细采集 ────────────────────────────────────────────
        // WATCH / LIVE 必采；SLEEP 下两种补充：
        // - 冷启动播种（否则水库永远为空，+°C 恒为 0）
        // - 定期重播种（刷新 share 分布，成本约每 8 分钟一次）
        let tickDelta = lastTick.map { now.timeIntervalSince($0) } ?? currentMode.interval
        defer { lastTick = now }

        // GPU busy 率：每 tick 增量 / 实际间隔。
        // 多 command queue 并行时累计值存在并发重复计量（原始值可 >1），
        // busy 语义封顶 1.0（w_g 标定与 SLEEP 回填都以此为口径）。
        var tickGPUSeconds = 0.0
        if let current = gpuCumulative {
            tickGPUSeconds = GPUSampler.deltas(current: current, previous: previousTickGPU)
                .values.reduce(0, +)
            previousTickGPU = current
        }
        let totalGPUBusy = min(tickGPUSeconds / max(tickDelta, 0.1), 1.0)

        // 设备级功耗每 tick 读一次（0.1ms 级）：w_g 标定 + 能耗对账共用
        let power = powerMeter?.readPower(now: now)
        if let power { lastPowerReading = power }

        let seedNeeded = !distributionSeeded
        let reseedNeeded = distributionSeeded && currentMode == .sleep && sleepTickCount >= sleepReseedInterval
        let collectDetails = currentMode.collectsProcessDetails || seedNeeded || reseedNeeded

        if collectDetails {
            let detailedDelta = lastDetailedTick.map { now.timeIntervalSince($0) } ?? tickDelta
            let samples = collector.collectSample(now: now, gpuCumulative: gpuCumulative).filter { $0.pid != ownPID }
            // PID reuse：仅失效被复用 PID 的归属缓存（§4.5），避免全量清空
            if !collector.cacheStalePIDs.isEmpty {
                resolver.invalidateCache(for: collector.cacheStalePIDs)
            }
            let allSamples = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            lastAppSamples = AppAggregator.aggregate(
                samples: samples,
                interval: max(detailedDelta, 0.1)
            ) { [resolver] sample in
                resolver.resolve(sample, allSamples: allSamples)
            }
            lastDetailedTick = now
            // 首帧 CPU/GPU 差分全为 0（无历史基准），采到有效分布才算播种完成
            if lastAppSamples.values.contains(where: { $0.cpu > 0.001 || $0.gpu > 0.001 }) {
                distributionSeeded = true
            }
        }
        sleepTickCount = currentMode == .sleep ? sleepTickCount + 1 : 0

        // ── 5. 热模型：无论是否详细采样，水库都按时间演化 ──────────
        let powerScores: [String: Double]
        if collectDetails {
            // Power Score = w_c·CPU + w_g·GPU（§8，v0.5 接入 GPU）
            powerScores = lastAppSamples.mapValues { $0.cpu + gpuWeight * $0.gpu }
        } else {
            // SLEEP 回填（热模型 v2 修复）：SLEEP 期间 App 仍在运行，
            // 水库不能只衰减。用廉价的全机 CPU 总量 + GPU busy 总量
            // （无需进程采样）按上次已知的 share 分布回填，保持 ΣH ≈ P_total × τ。
            powerScores = Self.sleepRefillScores(
                totalCPU: totalCPU,
                coreCount: coreCount,
                totalGPU: totalGPUBusy,
                gpuWeight: gpuWeight,
                shares: engine.heatShares()
            )
        }
        // 能耗对账（整活核心：每一度热都得有名字）。
        // 实测 CPU 封装瓦数超出进程归因的部分 = 硬件加速器
        // （摄像头 ISP / 视频编解码 / ANE）与内核驱动的热量，
        // 注入 System Hardware 伪 App 参与归因，而不是静默推高残差。
        var scores = powerScores
        lastHardwareGapCores = 0
        if let power {
            let gap = Self.hardwareGapCores(
                cpuWatts: power.cpuWatts,
                attributedCores: totalCPU * Double(coreCount),
                wattsPerCore: gpuWeightCalibrator.wattsPerCore
            )
            if gap > 0 {
                lastHardwareGapCores = gap
                // 归因优先级：正在采集麦克风的 App（语音/视频通话场景，
                // 摄像头 ISP / 编解码 / 音频 DSP 的热量算它的）→ 否则 System Hardware
                if let micAppID = micActiveAppID() {
                    scores[micAppID, default: 0] += gap
                    // SLEEP 间隙该 App 可能无进程样本，补合成样本保证热榜可见
                    if lastAppSamples[micAppID] == nil {
                        lastAppSamples[micAppID] = AppSample(appID: micAppID, processes: [], cpu: 0, gpu: 0)
                    }
                } else {
                    // 无麦克风候选：摄像头开着时标注上下文（客户端走 CMIO
                    // 扩展不可见，只能标注「摄像头在烧电」，不能点名）
                    lastCameraActive = cameraSampler.isFrontCameraStreaming()
                    scores[AppIdentity.systemHardware.id, default: 0] += gap
                }
            }
        }
        // 让缺口桶出现在热榜：有注入或有残存热量时生成合成 sample
        let hwID = AppIdentity.systemHardware.id
        if scores[hwID] != nil || (engine.reservoirs[hwID] ?? 0) > 1e-3 {
            lastAppSamples[hwID] = AppSample(appID: hwID, processes: [], cpu: 0, gpu: 0)
        }
        engine.ingest(powerScores: scores, deltaTime: max(tickDelta, 0.1))

        // ── 5.5 g 在线校准（热模型 v2 第三步，§14）───────────────
        // 实测温度为 ground truth：(T − 模型baseline) ≈ g × ΣH。
        // 校准时用的是注入后的最新水库，与展示口径一致。
        let totalHeat = engine.reservoirs.values.reduce(0, +)
        calibrator.update(
            temperature: temperature,
            modelBaseline: baseline.baseline,
            totalHeat: totalHeat,
            totalCPU: totalCPU,
            interval: tickDelta
        )

        // ── 5.6 w_g 在线标定（v0.5 Device Calibration，§8.2）───────
        // 设备级功耗 ÷ 负载 → GPU 满载瓦数与单核瓦数之比。
        // 护栏（GPU busy ≥0.2 / CPU ≥2 核）不满足时保持当前值。
        if let power {
            gpuWeightCalibrator.update(
                cpuWatts: power.cpuWatts,
                gpuWatts: power.gpuWatts,
                cpuCores: totalCPU * Double(coreCount),
                gpuBusy: totalGPUBusy,
                coreCount: coreCount
            )
        }

        let shares = engine.heatShares()
        // 热模型 v2：ΔT_i = g × H_i（§12.1）
        let deltaCs = engine.estimatedDeltaCs(gain: calibrator.gain)
        let totalDeltaC = deltaCs.values.reduce(0, +)
        let estimatedCelsius = temperature != nil || totalDeltaC > 0
            ? baseline.baseline + totalDeltaC
            : nil

        // ── 6. 组装快照 ─────────────────────────────────────────────
        let apps: [AppHeatInfo] = lastAppSamples.values
            .filter { (shares[$0.appID] ?? 0) > 0 }
            .map { sample in
                let identity = appsByID[sample.appID] ?? .other
                let delta = deltaCs[sample.appID] ?? 0
                return AppHeatInfo(
                    id: sample.appID,
                    name: identity.localizedName,
                    bundlePath: identity.bundlePath,
                    rootPid: identity.rootPid,
                    cpu: sample.cpu,
                    gpu: sample.gpu,
                    processCount: sample.processCount,
                    heatShare: shares[sample.appID] ?? 0,
                    estimatedDeltaC: delta,
                    isSystemComponent: identity.isSystemComponent,
                    // v0.8 What if I quit this?：稳态预期温度 = 当前温度 − 该 App 贡献
                    quitExpectedCelsius: temperature.map { $0 - delta }
                )
            }
            .sorted { $0.heatShare > $1.heatShare }

        // ── 7. 降温预测（v0.8）：置信度 + 进行中预测会话的里程碑 ──────
        let residualGap: Double? = if let temperature, let estimatedCelsius {
            temperature - estimatedCelsius
        } else { nil }
        let confidence = CoolingPrediction.confidence(residualGap: residualGap)

        var forecastInfo: CoolingForecastInfo?
        if let forecast = activeForecast {
            if let ms = forecast.milestones(now: now), !ms.isEmpty {
                forecastInfo = CoolingForecastInfo(
                    appName: forecast.appName,
                    milestones: ms,
                    steadyCelsius: forecast.startCelsius - forecast.steadyDrop,
                    steadyDrop: forecast.steadyDrop
                )
            } else {
                activeForecast = nil   // 剩余降幅 < 0.3°C，预测周期结束
            }
        }

        return MonitorSnapshot(
            temperatureCelsius: temperature,
            baselineCelsius: baseline.baseline,
            totalCPU: totalCPU,
            totalGPU: totalGPUBusy,
            thermalStateElevated: thermalElevated,
            mode: currentMode,
            apps: apps,
            appsTotalDeltaC: totalDeltaC,
            estimatedCelsius: estimatedCelsius,
            history: TemperatureHistorySummary(
                fiveMin: history.last5Minutes(now: now),
                oneHour: history.lastHour(now: now),
                twentyFourHours: history.last24Hours(now: now)
            ),
            coolingForecast: forecastInfo,
            predictionConfidence: confidence,
            cameraActive: lastCameraActive
        )
    }
}
