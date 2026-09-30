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

    public var currentMode: SamplingMode { modeController.mode }

    public init(
        temperatureProvider: TemperatureProvider = IOHIDTemperatureProvider(),
        tau: Double = 60,
        initialBaseline: Double = 45
    ) {
        self.temperatureProvider = temperatureProvider
        self.engine = ThermalEngine(tau: tau)
        self.baseline = BaselineTracker(initial: initialBaseline)
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
        let isIdle = totalCPU < 0.10 && !thermalElevated
        baseline.update(
            die: temperature,
            slowAnchor: reading.slowAnchorCelsius,
            isIdle: isIdle,
            now: now
        )

        // ── 4. 详细采集（WATCH / LIVE）─────────────────────────────
        let tickDelta = lastTick.map { now.timeIntervalSince($0) } ?? currentMode.interval
        defer { lastTick = now }

        if currentMode.collectsProcessDetails {
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
        }

        // ── 5. 热模型：无论是否详细采样，水库都按时间衰减 ──────────
        var powerScores: [String: Double] = [:]
        if currentMode.collectsProcessDetails {
            // v0.1 Power Score = CPU（§8：P_i = w_c·C_i，w_c = 1）
            powerScores = lastAppSamples.mapValues { $0.cpu }
        }
        engine.ingest(powerScores: powerScores, deltaTime: max(tickDelta, 0.1))

        let shares = engine.heatShares()
        let deltaCs = engine.estimatedDeltaCs(
            currentCelsius: temperature ?? baseline.baseline,
            baselineCelsius: baseline.baseline
        )

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
            apps: apps
        )
    }
}
