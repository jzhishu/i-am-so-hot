import AppKit
import OSLog
import ThermalCore

/// 监控调度服务：App 层与 ThermalCore 之间的桥（技术方案 §2 / §7）。
///
/// 调度策略（§7：单一调度器，禁止多 Timer）：
/// - 一个 DispatchSourceTimer，每次 tick 后按当前采样模式的 interval 重新调度。
/// - SLEEP 8s / WATCH 2.5s / LIVE 1s。
///
/// Event Monitor（§2）：监听 App 启动/退出，刷新注册表并失效归属缓存。
@MainActor
final class MonitorService {

    private let log = Logger(subsystem: "com.jzhishu.iamsohot", category: "monitor")

    private let monitor: ThermalMonitor
    private let registry = RunningAppRegistry()
    private var timer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// g 校准值持久化（UserDefaults）：重启后延续学习成果
    private static let gainDefaultsKey = "thermalGain.v1"
    private var lastSavedGain: Double = 0
    private var lastGainSaveTime: Date = .distantPast

    private(set) var snapshot: MonitorSnapshot?

    /// 每次产生新快照时回调（菜单栏标题 / 面板刷新）
    var onSnapshot: ((MonitorSnapshot) -> Void)?

    init() {
        let savedGain = UserDefaults.standard.object(forKey: Self.gainDefaultsKey) as? Double
        monitor = ThermalMonitor(initialGain: savedGain ?? 0.016)
        lastSavedGain = savedGain ?? 0.016
        refreshRegistry()
        observeWorkspaceEvents()
    }

    deinit {
        timer?.cancel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func start() {
        tick()
    }

    // MARK: - 面板状态（LIVE 触发条件）

    func setPanelOpen(_ open: Bool) {
        monitor.isPanelOpen = open
        if open {
            // 打开面板立即 tick 一次并进入 LIVE，避免等待上一个 SLEEP 周期
            timer?.cancel()
            tick()
        }
    }

    // MARK: - 用户操作

    func quit(_ app: AppHeatInfo) {
        guard app.canQuit else { return }
        let ok = registry.terminate(rootPid: app.rootPid)
        log.info("Quit \(app.name, privacy: .public): \(ok ? "requested" : "failed", privacy: .public)")
    }

    func icon(for app: AppHeatInfo) -> NSImage? {
        registry.icon(appID: app.id, bundlePath: app.bundlePath)
    }

    // MARK: - 调度循环

    private func tick() {
        let snapshot = monitor.tick()
        self.snapshot = snapshot
        onSnapshot?(snapshot)
        #if DEBUG
        debugExport(snapshot)
        #endif
        persistGainIfNeeded()
        log.info(
            "tick: mode=\(snapshot.mode.rawValue, privacy: .public) temp=\(snapshot.temperatureCelsius ?? -1, format: .fixed(precision: 1), privacy: .public)°C cpu=\(snapshot.totalCPU, format: .fixed(precision: 2), privacy: .public) apps=\(snapshot.apps.count, privacy: .public)"
        )
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        let interval = monitor.currentMode.interval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: - DEBUG 热模型数据导出（TechStack §5.2：校准 τ 用）

    #if DEBUG
    /// 将每次 tick 的关键指标追加到 /tmp/iamsohot-debug.csv，
    /// 用于对照实测温度曲线校准热模型参数（仅 Debug 构建）。
    private func debugExport(_ snapshot: MonitorSnapshot) {
        let url = URL(fileURLWithPath: "/tmp/iamsohot-debug.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "time,mode,temp,total_cpu,baseline,app_count,top_app,top_share,apps_sum_delta,est_temp,resid_baseline,gain\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        let top = snapshot.apps.first
        let line = String(
            format: "%.0f,%@,%.1f,%.3f,%.1f,%d,%@,%.3f,%.2f,%.1f,%.1f,%.4f\n",
            Date().timeIntervalSince1970,
            snapshot.mode.rawValue,
            snapshot.temperatureCelsius ?? -1,
            snapshot.totalCPU,
            snapshot.baselineCelsius,
            snapshot.apps.count,
            top?.name ?? "-",
            top?.heatShare ?? 0,
            snapshot.appsTotalDeltaC,
            snapshot.estimatedCelsius ?? -1,
            snapshot.residualBaselineCelsius ?? -1,
            monitor.thermalGain
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
    #endif

    // MARK: - g 校准值持久化（热模型 v2 第三步）

    /// 节流保存：校准值变化超过 0.0005 且距上次保存超过 60 秒才写盘。
    /// UserDefaults 写入极廉价，但避免每个 tick 都同步。
    private func persistGainIfNeeded() {
        let gain = monitor.thermalGain
        let now = Date()
        guard abs(gain - lastSavedGain) > 0.0005,
              now.timeIntervalSince(lastGainSaveTime) > 60 else { return }
        UserDefaults.standard.set(gain, forKey: Self.gainDefaultsKey)
        lastSavedGain = gain
        lastGainSaveTime = now
        log.info("thermal gain calibrated: \(gain, format: .fixed(precision: 4), privacy: .public)")
    }

    // MARK: - Event Monitor

    private func refreshRegistry() {
        let apps = registry.currentApps()
        monitor.updateAppRegistry(apps)
        log.debug("Registry refreshed: \(apps.count, privacy: .public) apps")
    }

    private func observeWorkspaceEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRegistry() }
            }
        }
    }
}
