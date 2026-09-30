import Foundation

/// g 在线校准器（热模型 v2 第三步，技术方案 §14）。
///
/// 问题：g（°C / core·s）的离线初值是单场景拟合的，换负载模式就失准——
/// 实测 90 秒 4 核压测中 est 低估实际温升约 4°C，误差被残差 baseline 吸收，
/// 导致展示 Baseline 在高负载下上浮。
///
/// 方法：递归最小二乘（RLS）。
/// 以实测温度为 ground truth：
///
///     y = T_measured − modelBaseline   （应归因给 App 的温升）
///     x = ΣH_i                          （全机热储量）
///     y ≈ g · x
///
/// 每 tick：
///     K = P·x / (λ + x·P·x)
///     g ← g + K·(y − g·x)
///     P ← (P − K·x·P) / λ
///
/// 护栏：
/// - 仅在热信号充足时回归（x > minHeat 且 totalCPU > minCPU），
///   怠速时 x≈0，除噪会把 g 带飞；
/// - 遗忘因子按时间换算（~10 分钟记忆窗口），适应设备状态缓慢漂移；
/// - g 钳制在 [min, max] 物理合理区间，单次异常采样不会造成突变。
public struct GainCalibrator: Sendable {

    /// 当前校准后的温升系数（°C / core·s）
    public private(set) var gain: Double
    /// RLS 方差项 P（估计不确定度）
    private var variance: Double

    /// 物理合理区间（°C / core·s）：超出即视为异常观测
    public static let gainBounds: ClosedRange<Double> = 0.005...0.05
    /// 回归所需最小热信号（core·s）
    public static let minHeat: Double = 0.5
    /// 回归所需最小负载
    public static let minCPU: Double = 0.05
    /// 记忆窗口（秒）：遗忘因子 λ = e^(−dt/window)
    public static let memoryWindow: TimeInterval = 600

    /// - Parameters:
    ///   - initial: 离线拟合初值或上次持久化的校准值
    ///   - variance: 初始不确定度；恢复持久化值时用较小方差（信任历史校准）
    public init(initial: Double, variance: Double = 1e-4) {
        self.gain = Self.gainBounds.clamped(initial)
        self.variance = variance
    }

    /// 每 tick 调用一次。不满足护栏条件时不更新（返回 false）。
    @discardableResult
    public mutating func update(
        temperature: Double?,
        modelBaseline: Double,
        totalHeat: Double,
        totalCPU: Double,
        interval: TimeInterval
    ) -> Bool {
        guard let temperature,
              totalHeat > Self.minHeat,
              totalCPU > Self.minCPU,
              interval > 0 else { return false }

        let y = temperature - modelBaseline
        let x = totalHeat
        let lambda = exp(-interval / Self.memoryWindow)

        let denominator = lambda + variance * x * x
        let k = variance * x / denominator
        gain += k * (y - gain * x)
        variance = (variance - k * x * variance) / lambda

        // 钳制：边界内收敛，边界外视为异常观测
        gain = Self.gainBounds.clamped(gain)
        variance = min(max(variance, 1e-8), 1e-2)
        return true
    }
}

private extension ClosedRange where Bound == Double {
    func clamped(_ value: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}
