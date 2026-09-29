import Foundation

/// 一次进程采样快照（技术方案 §17）。
///
/// v0.1 必需字段：pid / parentPid / executablePath / processName / cpuTimeDelta。
/// GPU / wakeups / IO 按 Roadmap 分阶段加入。
public struct ProcessSample: Sendable, Equatable {
    public let pid: pid_t
    public let parentPid: pid_t
    public let responsiblePid: pid_t?
    public let executablePath: String?
    public let processName: String
    /// 两次采样间的 CPU 时间增量（秒）
    public let cpuTimeDelta: TimeInterval

    public init(
        pid: pid_t,
        parentPid: pid_t,
        responsiblePid: pid_t? = nil,
        executablePath: String? = nil,
        processName: String,
        cpuTimeDelta: TimeInterval
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.responsiblePid = responsiblePid
        self.executablePath = executablePath
        self.processName = processName
        self.cpuTimeDelta = cpuTimeDelta
    }
}
