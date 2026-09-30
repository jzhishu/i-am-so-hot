import CoreFoundation
import CHIDBridge

/// 单个 HID 温度传感器读数。
public struct HIDTemperatureSensor: Sendable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// HID 温度传感器清点（调试/模型设计工具）。
///
/// Apple Silicon 上存在多类温度传感器：
/// - die 传感器（如 "PMU tdie*"）：随负载秒级波动 → 当前温度的主指标
/// - 慢速传感器（电池/机身等）：随环境温度分钟级漂移 → baseline 的物理锚点
public enum SensorInventory {

    private enum HID {
        static let sensorUsagePage = 0xFF00
        static let sensorUsage = 0x0005
        static let temperatureEventType: Int64 = 15
        static let temperatureLevelField = Int32(15) << 16
        static let validRange: ClosedRange<Double> = 0...150
    }

    /// 枚举当前全部温度传感器（名称 + 读数）。失败返回空数组。
    public static func all() -> [HIDTemperatureSensor] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            return []
        }
        let matching = [
            "PrimaryUsagePage": HID.sensorUsagePage,
            "PrimaryUsage": HID.sensorUsage,
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)

        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }

        return services.compactMap { service in
            guard let event = IOHIDServiceClientCopyEvent(
                service, HID.temperatureEventType, 0, 0
            )?.takeRetainedValue() else { return nil }
            let value = IOHIDEventGetFloatValue(event, HID.temperatureLevelField)
            guard HID.validRange.contains(value) else { return nil }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String ?? "unknown"
            return HIDTemperatureSensor(name: name, celsius: value)
        }
    }
}
