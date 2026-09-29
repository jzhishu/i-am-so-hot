import Foundation

/// 面板/App 层消费的 App 热量信息。
public struct AppHeatInfo: Sendable, Identifiable {
    public let id: String          // appID
    public let name: String
    public let bundlePath: String? // App 层用于查图标
    public let rootPid: pid_t?     // nil（macOS / Other）表示不可 Quit
    public let cpu: Double         // 核数口径，1.0 = 一个核满载
    public let processCount: Int
    public let heatShare: Double   // 0~1
    public let estimatedDeltaC: Double

    /// 系统归类（macOS / Other）不提供 Quit（PRD §8.3）
    public var canQuit: Bool { rootPid != nil }

    public init(
        id: String, name: String, bundlePath: String?, rootPid: pid_t?,
        cpu: Double, processCount: Int, heatShare: Double, estimatedDeltaC: Double
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.rootPid = rootPid
        self.cpu = cpu
        self.processCount = processCount
        self.heatShare = heatShare
        self.estimatedDeltaC = estimatedDeltaC
    }
}

/// 一次 tick 的完整快照，UI 只消费它（技术方案 §19：UI 不触发重型采样）。
public struct MonitorSnapshot: Sendable {
    public let temperatureCelsius: Double?
    public let baselineCelsius: Double
    /// 0~1，1 = 全部核满载
    public let totalCPU: Double
    public let thermalStateElevated: Bool
    public let mode: SamplingMode
    /// 按 heatShare 降序
    public let apps: [AppHeatInfo]

    public init(
        temperatureCelsius: Double?,
        baselineCelsius: Double,
        totalCPU: Double,
        thermalStateElevated: Bool,
        mode: SamplingMode,
        apps: [AppHeatInfo]
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.baselineCelsius = baselineCelsius
        self.totalCPU = totalCPU
        self.thermalStateElevated = thermalStateElevated
        self.mode = mode
        self.apps = apps
    }
}
