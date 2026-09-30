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
    /// 进程启动时间（epoch 秒）：PID reuse 检测——
    /// macOS 会复用 PID，同一 PID 前后可能是不同进程，
    /// 归属缓存与 CPU 差分遇到 startTime 变化必须失效
    public let startTimeSeconds: UInt64

    public init(
        pid: pid_t,
        parentPid: pid_t,
        responsiblePid: pid_t? = nil,
        executablePath: String? = nil,
        processName: String,
        cpuTimeDelta: TimeInterval,
        startTimeSeconds: UInt64 = 0
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.responsiblePid = responsiblePid
        self.executablePath = executablePath
        self.processName = processName
        self.cpuTimeDelta = cpuTimeDelta
        self.startTimeSeconds = startTimeSeconds
    }
}
