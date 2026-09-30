import Foundation

/// Apple Silicon 温度读取：IOHIDEventSystem 私有 API 实现（技术方案 §23 风险 1）。
///
/// 热模型 v2（§11.2）：一次 HID 枚举同时产出快慢两层读数：
/// - dieCelsius：die 传感器最大值 →「当前温度」
/// - slowAnchorCelsius：非 die/非 tcal 传感器最低值 → baseline 物理锚点
///
/// 全部失败时对应字段返回 nil，UI / 模型各自降级，互不影响。
public struct IOHIDTemperatureProvider: TemperatureProvider {

    public init() {}

    public func read() -> TemperatureReading {
        let sensors = SensorInventory.all()
        return TemperatureReading(
            dieCelsius: SensorClassifier.dieMax(sensors),
            slowAnchorCelsius: SensorClassifier.slowAnchor(sensors)
        )
    }
}
