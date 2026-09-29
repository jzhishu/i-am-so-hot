import Foundation

/// 温度读取抽象（技术方案 §23 风险 1：温度接口是本项目最大技术风险）。
///
/// Apple Silicon 无公开温度 API，v0.1 计划用 IOHIDEventSystem 私有 API 实现；
/// 通过协议隔离风险，读取失败时 UI 降级，不影响其他功能。
public protocol TemperatureProvider: Sendable {
    /// 当前主要温度（°C）。读取失败返回 nil。
    func currentCelsius() -> Double?
}

/// 占位实现：始终返回 nil。
/// TODO(Phase 1): 实现 IOHIDTemperatureProvider，并做真机可用性验证。
public struct UnavailableTemperatureProvider: TemperatureProvider {
    public init() {}
    public func currentCelsius() -> Double? { nil }
}
