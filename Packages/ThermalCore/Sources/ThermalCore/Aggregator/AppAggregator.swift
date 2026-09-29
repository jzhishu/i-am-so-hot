import Foundation

/// App 级聚合结果（技术方案 §17 AppSample）。
public struct AppSample: Sendable {
    public let appID: String
    public private(set) var processes: [ProcessSample]
    /// 聚合 CPU（核数口径，1.0 = 一个核满载，可超过 1），
    /// 与 Activity Monitor 的 %CPU 口径一致。
    public private(set) var cpu: Double

    public var processCount: Int { processes.count }

    public init(appID: String, processes: [ProcessSample], cpu: Double) {
        self.appID = appID
        self.processes = processes
        self.cpu = cpu
    }
}

/// App 聚合器（技术方案 §3.4）：
/// 将同一 App 下所有进程（Main / Helper / Renderer / GPU Process）聚合为一个 AppSample。
public enum AppAggregator {

    /// - Parameters:
    ///   - samples: 本次详细采样的全部进程
    ///   - interval: 距上次采样的实际间隔（秒），用于把 CPU 时间差分换算为使用率
    ///   - resolve: 归属解析函数
    public static func aggregate(
        samples: [ProcessSample],
        interval: TimeInterval,
        resolve: (ProcessSample) -> ProcessOwnership
    ) -> [String: AppSample] {
        guard interval > 0 else { return [:] }
        var byApp: [String: (processes: [ProcessSample], cpu: Double)] = [:]

        for sample in samples {
            let ownership = resolve(sample)
            let cpu = sample.cpuTimeDelta / interval
            var entry = byApp[ownership.appID] ?? ([], 0)
            entry.processes.append(sample)
            entry.cpu += cpu
            byApp[ownership.appID] = entry
        }

        var result: [String: AppSample] = [:]
        result.reserveCapacity(byApp.count)
        for (appID, entry) in byApp {
            result[appID] = AppSample(appID: appID, processes: entry.processes, cpu: entry.cpu)
        }
        return result
    }
}
