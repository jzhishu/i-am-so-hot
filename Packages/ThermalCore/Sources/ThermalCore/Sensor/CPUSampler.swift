import Darwin
import Foundation

/// CPU 采样器（技术方案 §5.2：优先 Mach / proc statistics）。
///
/// - Total CPU：`host_statistics(HOST_CPU_LOAD_INFO)`，两次采样差值计算。
/// - Per-process CPU time：`proc_pidinfo(PROC_PIDTASKINFO)`，
///   `pti_total_user + pti_total_system`（mach absolute time，需 timebase 换算），
///   由调用方做差分。
public final class CPUSampler {

    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    public init() {}

    /// 总体 CPU 使用率（0~1，1 = 全部核满载）。
    /// 首次调用建立基准并返回 nil。
    public func totalCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let ticks = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousTicks = ticks }
        guard let prev = previousTicks else { return nil }

        let dUser = ticks.user - prev.user
        let dSystem = ticks.system - prev.system
        let dIdle = ticks.idle - prev.idle
        let dNice = ticks.nice - prev.nice
        let dTotal = dUser + dSystem + dIdle + dNice
        guard dTotal > 0 else { return nil }
        return Double(dUser + dSystem + dNice) / Double(dTotal)
    }

    /// 单个进程累计 CPU 时间（秒，已做 timebase 换算）。进程不存在或无权访问时返回 nil。
    public func processCPUTime(_ pid: pid_t) -> TimeInterval? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard ret == size else { return nil }
        return MachTime.ticksToSeconds(info.pti_total_user + info.pti_total_system)
    }
}
