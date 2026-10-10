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
    /// 上次采样的每进程启动时间，用于 PID reuse 检测。
    private var previousStartTimes: [pid_t: UInt64] = [:]
    /// 上次详细采样的每进程累计 GPU 时间（纳秒）。
    /// 基准节奏与 CPU 一致——按详细采样间隔维护（review 修复：若按每 tick
    /// 差分，SLEEP reseed tick 的 GPU 功率会被 detailedDelta 错误归一化）。
    private var previousGPUTimes: [pid_t: UInt64] = [:]
    /// 本次采样发现需要清归属缓存的 PID（PID reuse：同 PID 启动时间变化）。
    /// 进程退出造成的缓存脏数据由注册表变化时的全量失效覆盖。
    public private(set) var cacheStalePIDs: [pid_t] = []

    public init() {}

    /// 采集当前全部进程快照。`cpuTimeDelta` / `gpuTimeDelta` 为相对上次
    /// 详细采样的增量（秒）。首次采样所有进程 delta 为 0（建立基准）。
    /// - Parameter gpuCumulative: 由调用方（ThermalMonitor）统一枚举的
    ///   per-process 累计 GPU 时间（纳秒）；nil 表示本次枚举失败，
    ///   GPU 基准保持不变（下一个成功的详细采样重新建立基准）。
    public func collectSample(
        now: Date = Date(),
        gpuCumulative: [pid_t: UInt64]? = nil
    ) -> [ProcessSample] {
        // GPU 差分与 CPU 同节奏：以本方法的调用间隔为基准
        let gpuDeltas = gpuCumulative.map { GPUSampler.deltas(current: $0, previous: previousGPUTimes) } ?? [:]
        if let gpuCumulative { previousGPUTimes = gpuCumulative }

        let pids = listAllPIDs()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)

        var newCPUTimes: [pid_t: (cpuTime: UInt64, at: Date)] = [:]
        newCPUTimes.reserveCapacity(pids.count)
        var stalePIDs: [pid_t] = []

        for pid in pids {
            guard pid > 0 else { continue }

            // CPU 累计时间
            var taskInfo = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            let taskInfoOK = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize) == taskSize

            // 名称与 PPID
            var bsdInfo = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let bsdInfoOK = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize

            // 异用户进程（如 _windowserver 的 WindowServer）proc_pidinfo 返回
            // EPERM。v0.5 起不再静默丢弃：proc_pidpath 对它们仍可读，生成
            // 最小 sample（CPU 无数据记 0，GPU 由 AGX 客户端属性照常覆盖），
            // 归属走系统规则进 macOS——否则 GPU 时间最大的常驻合成器会
            // 从归因中凭空蒸发（2026-10-09 review 发现，实测确认 EPERM）。
            let readable = taskInfoOK && bsdInfoOK

            let name: String
            let ppid: pid_t
            let startTime: UInt64
            if readable {
                name = withUnsafeBytes(of: bsdInfo.pbi_name) { raw -> String in
                    guard let base = raw.baseAddress else { return "" }
                    return String(cString: base.assumingMemoryBound(to: CChar.self))
                }
                ppid = pid_t(bsdInfo.pbi_ppid)
                startTime = UInt64(bsdInfo.pbi_start_tvsec)
            } else {
                name = ""  // 回退为可执行路径末段（见下）
                ppid = 0   // PPID 追溯不可用，responsible/路径规则照常
                startTime = 0
            }

            // 可执行路径（部分系统进程无路径，返回 nil 属正常）
            let path = executablePath(for: pid)

            if !readable {
                // EPERM 进程不参与 CPU 差分基准（无数据），但保留 GPU 基准
                samples.append(ProcessSample(
                    pid: pid,
                    parentPid: ppid,
                    responsiblePid: nil,
                    executablePath: path,
                    processName: name.isEmpty ? (path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "") : name,
                    cpuTimeDelta: 0,
                    gpuTimeDelta: gpuDeltas[pid] ?? 0,
                    startTimeSeconds: startTime
                ))
                continue
            }

            let cpuTime = taskInfo.pti_total_user + taskInfo.pti_total_system
            newCPUTimes[pid] = (cpuTime, now)

            // responsible PID（WebKit XPC 等跨 bundle 子进程归属，技术方案 §4.3）
            let responsible = responsibility_get_pid_responsible_for_pid(pid)

            // PID reuse 检测：同一 PID 启动时间变化 = 旧进程已退出、PID 被复用
            if let prevStart = previousStartTimes[pid], prevStart != startTime {
                stalePIDs.append(pid)
            }

            // CPU 差分（mach ticks -> 秒）
            // 仅当确认非 PID 复用时，与上次采样的差分才有意义
            let delta: TimeInterval
            if let prev = previousCPUTimes[pid], cpuTime >= prev.cpuTime,
               previousStartTimes[pid] == startTime {
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
                cpuTimeDelta: delta,
                gpuTimeDelta: gpuDeltas[pid] ?? 0,
                startTimeSeconds: startTime
            ))
        }

        previousCPUTimes = newCPUTimes
        previousStartTimes = Dictionary(
            samples.map { ($0.pid, $0.startTimeSeconds) },
            uniquingKeysWith: { first, _ in first }
        )
        cacheStalePIDs = stalePIDs
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
