import CoreFoundation
import CHIDBridge

/// Apple Silicon 温度读取：IOHIDEventSystem 私有 API 实现（技术方案 §23 风险 1）。
///
/// 读取策略：
/// - 遍历 usage page 0xFF00 / usage 0x0005 下的 HID 传感器服务。
/// - 优先返回名称含 "die"（如 PMU tdie*）的传感器最大值（SoC die 温度）。
/// - 兜底返回其余温度传感器最大值。
/// - 全部失败返回 nil，UI 降级（不影响其他功能）。
public struct IOHIDTemperatureProvider: TemperatureProvider {

    private enum HID {
        /// Apple vendor-defined 传感器页
        static let sensorUsagePage = 0xFF00
        static let sensorUsage = 0x0005
        /// kIOHIDEventTypeTemperature
        static let temperatureEventType: Int64 = 15
        /// kIOHIDEventFieldTemperatureLevel = IOHIDEventFieldBase(kIOHIDEventTypeTemperature)
        static let temperatureLevelField = Int32(15) << 16
        /// 合理温度区间（°C），过滤异常读数
        static let validRange: ClosedRange<Double> = 0...150
    }

    public init() {}

    public func currentCelsius() -> Double? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            return nil
        }
        let matching = [
            "PrimaryUsagePage": HID.sensorUsagePage,
            "PrimaryUsage": HID.sensorUsage,
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)

        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef],
              !services.isEmpty else {
            return nil
        }

        var dieTemps: [Double] = []
        var otherTemps: [Double] = []

        for service in services {
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard let event = IOHIDServiceClientCopyEvent(
                service, HID.temperatureEventType, 0, 0
            )?.takeRetainedValue() else { continue }

            let value = IOHIDEventGetFloatValue(event, HID.temperatureLevelField)
            guard HID.validRange.contains(value) else { continue }

            if name.localizedCaseInsensitiveContains("die") {
                dieTemps.append(value)
            } else {
                otherTemps.append(value)
            }
        }

        return dieTemps.max() ?? otherTemps.max()
    }
}
