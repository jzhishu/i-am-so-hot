import Foundation

/// 动态 Baseline 学习（技术方案 §11）。
///
/// Baseline = 当前设备在相同环境下、没有显著高负载软件时的预计温度。
///
/// v0.1 简化实现：
/// - 只在 idle 条件满足时学习（避免高负载污染 baseline）。
/// - 使用小 alpha 的 EMA 缓慢收敛。
/// - v0.5 将增强：考虑充电状态 / 外接显示器 / 长时间负载历史等。
public struct BaselineTracker: Sendable {

    /// 当前 baseline（°C）
    public private(set) var baseline: Double

    /// EMA 学习率（每次 idle 采样向实测温度靠近的比例）。
    /// 0.005 ≈ 200 次 idle 采样收敛 63%。
    public let alpha: Double

    public init(initial: Double = 45, alpha: Double = 0.005) {
        self.baseline = initial
        self.alpha = alpha
    }

    /// 每次采样后调用。
    /// - Parameters:
    ///   - currentCelsius: 当前温度（nil 时不学习）
    ///   - isIdle: 是否满足 idle 条件（低 CPU + thermalState nominal），
    ///     由调用方判定（技术方案 §11.3）
    public mutating func update(currentCelsius: Double?, isIdle: Bool) {
        guard isIdle, let current = currentCelsius else { return }
        baseline = (1 - alpha) * baseline + alpha * current
    }
}
