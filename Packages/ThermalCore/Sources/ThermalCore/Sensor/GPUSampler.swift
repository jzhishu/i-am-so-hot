import Foundation
import IOKit

/// GPU 采样器（v0.5 GPU Attribution，技术方案 §5.3 / §8）。
///
/// Apple Silicon 无公开 per-process GPU API。经真机调研（2026-10-09，M2 Pro）：
/// IORegistry 中的 `AGXDeviceUserClient` 条目暴露两个关键属性，无需 root：
/// - `IOUserClientCreator`："pid 1234, ProcessName"
/// - `AppUsage`：按 CommandQueue 的 `[{API, lastSubmittedTime, accumulatedGPUTime}]`
///
/// `accumulatedGPUTime` 单位为纳秒（实测 WindowServer 3.12e12 ≈ 52 分钟，
/// 与常驻合成器身份吻合），对该值按 pid 求和 + 差分即得 per-process GPU 时间，
/// 与 CPU 时间的差分模式完全同构。
///
/// 已知边界（允许不精确，Heat Share 语义不受影响）：
/// - client 关闭/重建时累计值归零，差分出现负值 → 钳为 0（丢失少量尾部时间）；
/// - PID reuse：GPU 侧无启动时间可校验，依赖负值钳制兜底；
/// - 属性是调试性质的非文档接口，读取失败时整体降级为无 GPU 数据。
///
/// 枚举路径（踩坑记录）：AGXDeviceUserClient 条目是 !registered 状态，
/// IOServiceMatching("AGXDeviceUserClient") 匹配不到，必须先匹配
/// IOAccelerator（AGXAcceleratorG14X 等设备节点），再在 IOService plane
/// 下遍历其子节点。多 GPU 设备（外接/dGPU）由外层循环自然覆盖。
///
/// 成本：一次枚举约 1~2ms（~60 个 entry），每 tick 调用一次，
/// SLEEP 8s 间隔下占空比 ~0.02%，在性能预算内。
public final class GPUSampler {

    /// 上次采样的每进程累计 GPU 时间（纳秒，多 client 已按 pid 求和）
    private var previousGPUTimes: [pid_t: UInt64] = [:]

    /// 上一次是否成功枚举到任何 GPU client。
    /// 用于区分「本机不支持/读取失败」与「当前无 GPU 用户」，
    /// 失败后上层可整体降级，不再重复尝试。
    public private(set) var isAvailable = true

    public init() {}

    /// 采样全部 GPU client，返回 pid -> 距上次采样的 GPU 时间增量（秒）。
    /// 首次调用建立基准并返回空字典。
    /// 枚举失败时置 isAvailable = false 并返回空字典。
    public func gpuTimeDeltas() -> [pid_t: TimeInterval] {
        guard let current = readCumulativeGPUTimes() else {
            isAvailable = false
            return [:]
        }
        defer { previousGPUTimes = current }

        var deltas: [pid_t: TimeInterval] = [:]
        for (pid, gpuTime) in current {
            guard let prev = previousGPUTimes[pid] else { continue }  // 新 client：建立基准
            // client 重建 / PID reuse：累计值回退，差分无意义，钳 0
            guard gpuTime >= prev else { continue }
            let delta = gpuTime - prev
            if delta > 0 {
                deltas[pid] = Double(delta) / 1_000_000_000
            }
        }
        return deltas
    }

    /// 当前全部 GPU client 的累计 GPU 时间（纳秒），按 pid 求和。
    /// 返回 nil 表示枚举失败（IORegistry 不可用）。
    private func readCumulativeGPUTimes() -> [pid_t: UInt64]? {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard kr == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: [pid_t: UInt64] = [:]
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            collectClients(of: device, into: &result)
        }
        return result
    }

    /// 遍历一个 GPU 设备节点下的全部 AGXDeviceUserClient 子节点。
    private func collectClients(of device: io_registry_entry_t, into result: inout [pid_t: UInt64]) {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(childIterator) }

        while case let client = IOIteratorNext(childIterator), client != 0 {
            defer { IOObjectRelease(client) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(client, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = propsRef?.takeRetainedValue() as? [String: Any] else { continue }
            guard let pid = Self.parsePID(from: properties["IOUserClientCreator"] as? String) else { continue }
            let gpuTime = Self.sumAppUsage(properties["AppUsage"])
            if gpuTime > 0 {
                result[pid, default: 0] += gpuTime
            }
        }
    }

    /// 解析 "pid 1234, ProcessName" 格式的 creator 字符串。
    /// 进程名可能含逗号，只取第一个逗号前的数字。
    static func parsePID(from creator: String?) -> pid_t? {
        guard let creator, creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        guard let comma = rest.firstIndex(of: ","),
              let pid = pid_t(rest[rest.startIndex..<comma]) else { return nil }
        return pid > 0 ? pid : nil
    }

    /// 累加 AppUsage 数组中所有 command queue 的 accumulatedGPUTime。
    static func sumAppUsage(_ appUsage: Any?) -> UInt64 {
        guard let entries = appUsage as? [[String: Any]] else { return 0 }
        return entries.reduce(0) { sum, entry in
            sum + ((entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
    }
}
