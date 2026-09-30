import Foundation

/// 一次温度读取结果（热模型 v2，技术方案 §11.2 传感器分层）。
public struct TemperatureReading: Sendable {
    /// 快层：die 传感器（随负载秒级波动）→「当前温度」主指标
    public let dieCelsius: Double?
    /// 慢层：电池/机身传感器（随环境分钟级漂移）→ baseline 物理锚点
    public let slowAnchorCelsius: Double?

    public init(dieCelsius: Double?, slowAnchorCelsius: Double?) {
        self.dieCelsius = dieCelsius
        self.slowAnchorCelsius = slowAnchorCelsius
    }
}

/// 温度读取抽象（技术方案 §23 风险 1：温度接口是本项目最大技术风险）。
///
/// Apple Silicon 无公开温度 API，v0.1 起用 IOHIDEventSystem 私有 API 实现；
/// 通过协议隔离风险，读取失败时 UI 降级，不影响其他功能。
public protocol TemperatureProvider: Sendable {
    func read() -> TemperatureReading
}

/// 占位实现：始终返回空读数。
public struct UnavailableTemperatureProvider: TemperatureProvider {
    public init() {}
    public func read() -> TemperatureReading {
        TemperatureReading(dieCelsius: nil, slowAnchorCelsius: nil)
    }
}
