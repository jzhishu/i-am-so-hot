import Darwin
import Foundation
import CHIDBridge

/// proc_taskinfo 的 pti_total_user / pti_total_system 单位是
/// mach absolute time（实测 Apple Silicon：125/3 ns 每 tick），
/// 需要 mach_timebase_info 换算成纳秒。
enum MachTime {
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func ticksToSeconds(_ ticks: UInt64) -> TimeInterval {
        Double(ticks) * nanosecondsPerTick / 1_000_000_000
    }
}

/// 进程采集器（技术方案 §3.2 / §5）。
///
/// 每次详细采样通过 libproc 获取：
/// PID / PPID / 进程名 / 可执行路径 / CPU time 差分。
///
/// 成本说明：proc_pidinfo 按进程逐个调用，是详细采样的主要开销，
/// 因此只在 WATCH / LIVE 模式下由 ThermalMonitor 触发。
public final class ProcessCollector {

    /// 上次采样的每进程累计 CPU 时间（纳秒）与采样时刻，用于差分。
    private var previousCPUTimes: [pid_t: (cpuTime: UInt64, at: Date)] = [:]

    public init() {}

    /// 采集当前全部进程快照。`cpuTimeDelta` 为相对上次采样的增量（秒）。
    /// 首次采样所有进程 delta 为 0（建立基准）。
    public func collectSample(now: Date = Date()) -> [ProcessSample] {
        let pids = listAllPIDs()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)

        var newCPUTimes: [pid_t: (cpuTime: UInt64, at: Date)] = [:]
        newCPUTimes.reserveCapacity(pids.count)

        for pid in pids {
            guard pid > 0 else { continue }

            // CPU 累计时间
            var taskInfo = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize) == taskSize else {
                continue
            }
            let cpuTime = taskInfo.pti_total_user + taskInfo.pti_total_system
            newCPUTimes[pid] = (cpuTime, now)

            // 名称与 PPID
            var bsdInfo = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize else {
                continue
            }
            let name = withUnsafeBytes(of: bsdInfo.pbi_name) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            let ppid = pid_t(bsdInfo.pbi_ppid)

            // 可执行路径（部分系统进程无路径，返回 nil 属正常）
            let path = executablePath(for: pid)

            // responsible PID（WebKit XPC 等跨 bundle 子进程归属，技术方案 §4.3）
            let responsible = responsibility_get_pid_responsible_for_pid(pid)

            // CPU 差分（mach ticks -> 秒）
            let delta: TimeInterval
            if let prev = previousCPUTimes[pid], cpuTime >= prev.cpuTime {
                delta = MachTime.ticksToSeconds(cpuTime - prev.cpuTime)
            } else {
                delta = 0
            }

            samples.append(ProcessSample(
                pid: pid,
                parentPid: ppid,
                responsiblePid: responsible > 0 ? responsible : nil,
                executablePath: path,
                processName: name,
                cpuTimeDelta: delta
            ))
        }

        previousCPUTimes = newCPUTimes
        return samples
    }

    private func listAllPIDs() -> [pid_t] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
