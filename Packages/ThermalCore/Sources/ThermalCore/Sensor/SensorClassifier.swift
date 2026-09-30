import Foundation

/// 传感器分类器（热模型 v2，技术方案 §11.2）。
///
/// 纯函数实现，便于单元测试。分类规则基于本机实测（26 个传感器）：
/// - 快层：名称含 "die"（PMU tdie*），42~44°C，随负载秒级波动
/// - 慢层：非 die、非 tcal（电池/机身类），33~35°C，随环境分钟级漂移
public enum SensorClassifier {

    /// 快层「当前温度」：die 传感器最大值。
    /// 无 die 传感器时（异常情况）降级为全部传感器最大值。
    public static func dieMax(_ sensors: [HIDTemperatureSensor]) -> Double? {
        let die = sensors
            .filter { $0.name.localizedCaseInsensitiveContains("die") }
            .map(\.celsius)
        if let maxDie = die.max() { return maxDie }
        return sensors.map(\.celsius).max()
    }

    /// 慢层 baseline 锚点：非 die、非 tcal 传感器的**最低值**。
    ///
    /// 取最低值的理由（技术方案 §11.3）：
    /// 多传感器取最低可自然剔除异常热源（如电池充电自发热），
    /// 锚定最接近环境/机身基础温度的传感器。
    /// 无慢层传感器时返回 nil（调用方走退化模式）。
    public static func slowAnchor(_ sensors: [HIDTemperatureSensor]) -> Double? {
        sensors
            .filter {
                !$0.name.localizedCaseInsensitiveContains("die")
                    && !$0.name.localizedCaseInsensitiveContains("tcal")
            }
            .map(\.celsius)
            .min()
    }
}
