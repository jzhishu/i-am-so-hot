import Foundation

/// 设备级功耗计（v0.5 Device Calibration 前置，技术方案 §8.2）。
///
/// 通过 libIOReport（私有 dylib，运行时 dlopen/dlsym 隔离符号）订阅
/// "Energy Model" 组的设备级能量累计通道：
/// - `CPU Energy`（单位 mJ，含 E/P 核与 SRAM）
/// - `GPU Energy`（单位 nJ）
///
/// 两次采样差分 ÷ 间隔 = 设备级 CPU / GPU 功率（瓦特）。
/// 用途：在线标定 GPU 权重 w_g（GPUWeightCalibrator），不进入 UI。
///
/// 实测口径（2026-10-09，M2 Pro）：
/// - 空闲：CPU ~0.5W / GPU ~0.04W
/// - 6 核 CPU 压测：CPU 9.2W（≈1.44W/核增量）
/// - Metal GPU 压测：GPU 12.2W（busy≈0.9 → 满载 ≈13.5W）
///
/// 失败降级：任何一步失败置 isAvailable = false，上层保持经验 w_g。
public final class DevicePowerMeter {

    /// 一次设备级功耗读数（瓦特）
    public struct PowerReading {
        public let cpuWatts: Double
        public let gpuWatts: Double
    }

    public private(set) var isAvailable = false

    // MARK: - libIOReport 动态符号（私有 API 隔离：不链接、不暴露头文件）

    private typealias CopyInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFTypeRef>?
    private typealias CreateSubFn = @convention(c) (CFTypeRef?, CFTypeRef, UnsafeMutablePointer<Unmanaged<CFMutableArray>?>?, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamplesFn = @convention(c) (CFTypeRef?, CFMutableArray?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaFn = @convention(c) (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SimpleGetIntFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamplesFn
    private let createDelta: CreateDeltaFn
    private let simpleGetInt: SimpleGetIntFn

    private var subscription: CFTypeRef?
    private var subscribedChannels: CFMutableArray?
    private var previousSample: CFDictionary?
    private var previousSampleTime: Date?

    public init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY),
              let copyInGroup = Self.loadSym(handle, "IOReportCopyChannelsInGroup", CopyInGroupFn.self),
              let createSub = Self.loadSym(handle, "IOReportCreateSubscription", CreateSubFn.self),
              let createSamples = Self.loadSym(handle, "IOReportCreateSamples", CreateSamplesFn.self),
              let createDelta = Self.loadSym(handle, "IOReportCreateSamplesDelta", CreateDeltaFn.self),
              let simpleGetInt = Self.loadSym(handle, "IOReportSimpleGetIntegerValue", SimpleGetIntFn.self)
        else { return nil }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.simpleGetInt = simpleGetInt

        // 订阅 Energy Model 组（含 CPU Energy / GPU Energy 等 ~177 个设备级通道）
        guard let groupRef = copyInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let groupDict = groupRef as? [String: Any] else { return nil }

        // 只保留目标通道，降低每次采样成本
        let wanted: Set<String> = ["CPU Energy", "GPU Energy"]
        let channels = (groupDict["IOReportChannels"] as? [Any] ?? []).filter { ch in
            guard let dict = ch as? [String: Any],
                  let legend = dict["LegendChannel"] as? [Any],
                  let name = legend.last as? String else { return false }
            return wanted.contains(name)
        }
        guard channels.count == wanted.count else { return nil }

        let filteredRef = ["IOReportChannels": channels] as CFDictionary
        var subbed: Unmanaged<CFMutableArray>?
        guard let sub = createSub(nil, filteredRef, &subbed, 0, nil)?.takeRetainedValue(),
              let subbedArr = subbed?.takeRetainedValue() else { return nil }
        self.subscription = sub
        self.subscribedChannels = subbedArr
        self.isAvailable = true
    }

    private static func loadSym<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        guard let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// 读取设备级 CPU / GPU 功率（瓦特）。首次调用建立基准并返回 nil。
    public func readPower(now: Date = Date()) -> PowerReading? {
        guard isAvailable,
              let sub = subscription,
              let channels = subscribedChannels,
              let sample = createSamples(sub, channels, nil)?.takeRetainedValue() else { return nil }
        defer {
            previousSample = sample
            previousSampleTime = now
        }
        guard let prev = previousSample, let prevTime = previousSampleTime,
              let delta = createDelta(prev, sample, nil)?.takeRetainedValue() as? [String: Any],
              let entries = delta["IOReportChannels"] as? [Any] else { return nil }

        let interval = now.timeIntervalSince(prevTime)
        guard interval > 0.1 else { return nil }

        var cpuMillijoules: Double?
        var gpuNanojoules: Double?
        for entry in entries {
            guard let dict = entry as? [String: Any],
                  let legend = dict["LegendChannel"] as? [Any],
                  let name = legend.last as? String else { continue }
            let raw = simpleGetInt(entry as! CFDictionary, 0)
            switch name {
            case "CPU Energy": cpuMillijoules = Double(raw)          // 单位 mJ
            case "GPU Energy": gpuNanojoules = Double(raw)           // 单位 nJ
            default: break
            }
        }
        guard let cpuMJ = cpuMillijoules, let gpuNJ = gpuNanojoules else { return nil }
        return PowerReading(
            cpuWatts: cpuMJ / 1000 / interval,
            gpuWatts: gpuNJ / 1_000_000_000 / interval
        )
    }
}
