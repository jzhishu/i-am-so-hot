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
    /// SLEEP 下每 N 个 tick 做一次详细采样刷新 share 分布（8s × 60 ≈ 8 分钟）
    private let sleepReseedInterval = 60
    /// share 分布是否已建立。首次详细采样所有进程 CPU 差分为 0（无历史基准），
    /// 必须采到第二帧才有有效分布，因此播种是一个过程而不是一次采样。
    private var distributionSeeded = false
    /// 逻辑核数（SLEEP 回填时把 0~1 总 CPU 换算为核数口径功率）
    private let coreCount = ProcessInfo.processInfo.processorCount

    public var currentMode: SamplingMode { modeController.mode }

    /// 温升系数 g（°C / 单位热储量）——热模型 v2 §12.1。
    /// 初值 0.016：2026-09-30 用本机 4 核压测 CSV 离线拟合（范围 0.011–0.020，
    /// 取中段中位数；与 τ=60 配对，第三步在线联合校准）。
    public var thermalGain: Double = 0.016

    public init(
        temperatureProvider: TemperatureProvider = IOHIDTemperatureProvider(),
        tau: Double = 60,
        initialBaseline: Double = 45
    ) {
        self.temperatureProvider = temperatureProvider
        self.engine = ThermalEngine(tau: tau)
        self.baseline = BaselineTracker(initial: initialBaseline)
    }

    /// SLEEP 模式水库回填（纯函数，便于单测）：
    /// 把全机总功率（totalCPU × 核数）按上次已知的 share 分布拆分。
    /// 分布失效（水库为空）时返回空，不产生臆造数据。
    static func sleepRefillScores(
        totalCPU: Double,
        coreCount: Int,
        shares: [String: Double]
    ) -> [String: Double] {
        guard totalCPU > 0, coreCount > 0, !shares.isEmpty else { return [:] }
        let totalPower = totalCPU * Double(coreCount)
        return shares.mapValues { $0 * totalPower }
    }

    /// 注入 App 注册表（App 启动/退出事件时调用，并清空归属缓存）。
    public func updateAppRegistry(_ apps: [AppIdentity]) {
        appsByID = Dictionary(
            apps.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        appsByID[AppIdentity.macOS.id] = .macOS
        appsByID[AppIdentity.other.id] = .other
        resolver.updateRegistry(apps)
        resolver.invalidateCache()
    }

    @discardableResult
    public func tick(now: Date = Date()) -> MonitorSnapshot {
        // ── 1. 廉价指标 ─────────────────────────────────────────────
        let totalCPU = cpuSampler.totalCPU() ?? 0
        let reading = temperatureProvider.read()
        let temperature = reading.dieCelsius
        let thermalElevated = ProcessInfo.processInfo.thermalState != .nominal

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

        let seedNeeded = !distributionSeeded
        let reseedNeeded = distributionSeeded && currentMode == .sleep && sleepTickCount >= sleepReseedInterval
        let collectDetails = currentMode.collectsProcessDetails || seedNeeded || reseedNeeded

        if collectDetails {
            let detailedDelta = lastDetailedTick.map { now.timeIntervalSince($0) } ?? tickDelta
            let samples = collector.collectSample(now: now).filter { $0.pid != ownPID }
            let allSamples = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            lastAppSamples = AppAggregator.aggregate(
                samples: samples,
                interval: max(detailedDelta, 0.1)
            ) { [resolver] sample in
                resolver.resolve(sample, allSamples: allSamples)
            }
            lastDetailedTick = now
            // 首帧 CPU 差分全为 0（无历史基准），采到有效分布才算播种完成
            if lastAppSamples.values.contains(where: { $0.cpu > 0.001 }) {
                distributionSeeded = true
            }
        }
        sleepTickCount = currentMode == .sleep ? sleepTickCount + 1 : 0

        // ── 5. 热模型：无论是否详细采样，水库都按时间演化 ──────────
        let powerScores: [String: Double]
        if collectDetails {
            // v0.1 Power Score = CPU（§8：P_i = w_c·C_i，w_c = 1）
            powerScores = lastAppSamples.mapValues { $0.cpu }
        } else {
            // SLEEP 回填（热模型 v2 修复）：SLEEP 期间 App 仍在运行，
            // 水库不能只衰减。用廉价的全机 CPU 总量（无需进程采样）
            // 按上次已知的 share 分布回填，保持 ΣH ≈ P_total × τ。
            powerScores = Self.sleepRefillScores(
                totalCPU: totalCPU,
                coreCount: coreCount,
                shares: engine.heatShares()
            )
        }
        engine.ingest(powerScores: powerScores, deltaTime: max(tickDelta, 0.1))

        let shares = engine.heatShares()
        // 热模型 v2：ΔT_i = g × H_i（§12.1）
        let deltaCs = engine.estimatedDeltaCs(gain: thermalGain)
        let totalDeltaC = deltaCs.values.reduce(0, +)
        let estimatedCelsius = temperature != nil || totalDeltaC > 0
            ? baseline.baseline + totalDeltaC
            : nil

        // ── 6. 组装快照 ─────────────────────────────────────────────
        let apps: [AppHeatInfo] = lastAppSamples.values
            .filter { (shares[$0.appID] ?? 0) > 0 }
            .map { sample in
                let identity = appsByID[sample.appID] ?? .other
                return AppHeatInfo(
                    id: sample.appID,
                    name: identity.localizedName,
                    bundlePath: identity.bundlePath,
                    rootPid: identity.rootPid,
                    cpu: sample.cpu,
                    processCount: sample.processCount,
                    heatShare: shares[sample.appID] ?? 0,
                    estimatedDeltaC: deltaCs[sample.appID] ?? 0
                )
            }
            .sorted { $0.heatShare > $1.heatShare }

        return MonitorSnapshot(
            temperatureCelsius: temperature,
            baselineCelsius: baseline.baseline,
            totalCPU: totalCPU,
            thermalStateElevated: thermalElevated,
            mode: currentMode,
            apps: apps,
            appsTotalDeltaC: totalDeltaC,
            estimatedCelsius: estimatedCelsius
        )
    }
}
