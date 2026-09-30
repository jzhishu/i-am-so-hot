import Foundation

/// 动态 Baseline（热模型 v2，技术方案 §11）。
///
/// Baseline = 当前设备在相同环境下、没有显著高负载软件时的预计温度。
///
/// v2 计算（§11.3）：
///
///     B(t) = T_slow(t) + δ
///
/// - T_slow：慢层传感器锚点（电池/机身，几乎不受瞬时负载影响）
/// - δ：die 与慢层在 idle + 温度稳定时学习的偏移量（本机约 9°C）
///
/// 不对称跟踪（§11.4，结构性保证 baseline 不高于当前温度）：
/// - T < B：δ（或退化模式的 B）快速下修追向 T
/// - T ≥ B：只允许在 idle + 温度稳定时慢速上调
///
/// 无慢层传感器的设备退化为不对称 EMA（直接作用于 B）。
public struct BaselineTracker: Sendable {

    /// 当前 baseline（°C）
    public private(set) var baseline: Double

    /// 首个有效温度直接作为 baseline（冷启动）
    public private(set) var isInitialized = false

    /// die 与慢层锚点的偏移量 δ（°C）。nil = 尚未获得慢层读数。
    public private(set) var offset: Double?

    // MARK: - 可调参数（需经真实设备校准，技术方案 §14）

    /// δ 合理区间（°C）
    public var offsetRange: ClosedRange<Double> = 2...15
    /// δ 慢速学习率（每次满足学习条件的采样）
    public var idleAlpha: Double = 0.02
    /// T < B 时的快速下修比例（每次采样）
    public var downAdjustmentRate: Double = 0.3
    /// 温度稳定判断窗口（秒）
    public var stabilityWindow: TimeInterval = 60
    /// 窗口内允许的最大温度波动（°C）
    public var stabilityTolerance: Double = 0.5

    /// 近期 die 温度（稳定性判断用）
    private var recentDie: [(value: Double, at: Date)] = []

    public init(initial: Double = 45) {
        self.baseline = initial
    }

    /// 近期 die 温度是否稳定（§11.5：排除负载后的降温尾巴）
    public var isStable: Bool {
        guard let oldest = recentDie.first,
              let newest = recentDie.last,
              newest.at.timeIntervalSince(oldest.at) >= stabilityWindow / 2 else {
            return false
        }
        let values = recentDie.map(\.value)
        return (values.max()! - values.min()!) <= stabilityTolerance
    }

    /// 每次采样后调用。
    /// - Parameters:
    ///   - die: 快层温度（°C），nil 时不更新
    ///   - slowAnchor: 慢层锚点（°C），nil 时走退化模式
    ///   - isIdle: 低 CPU + thermalState nominal（调用方判定，§11.5）
    ///   - now: 采样时刻
    public mutating func update(
        die: Double?,
        slowAnchor: Double?,
        isIdle: Bool,
        now: Date = Date()
    ) {
        guard let die else { return }

        // 维护稳定性窗口
        recentDie.append((die, now))
        recentDie.removeAll { now.timeIntervalSince($0.at) > stabilityWindow }

        if !isInitialized {
            baseline = die
            isInitialized = true
        }

        if let slow = slowAnchor {
            updateWithAnchor(die: die, slow: slow, isIdle: isIdle)
        } else {
            updateFallback(die: die, isIdle: isIdle)
        }
    }

    // MARK: - 慢层锚点模式（§11.3 / §11.4）

    private mutating func updateWithAnchor(die: Double, slow: Double, isIdle: Bool) {
        guard var delta = offset else {
            // 首个慢层读数：用当前 die - slow 初始化 δ
            offset = clampOffset(die - slow)
            baseline = die
            return
        }

        // 不对称下修：T < B 时 δ 快速减小，使 B 追向 T
        let b = slow + delta
        if die < b {
            delta -= (b - die) * downAdjustmentRate
            delta = clampOffset(delta)
        }

        // 慢速学习：仅 idle + 温度稳定（§11.5）
        if isIdle && isStable {
            let learned = die - slow
            delta = clampOffset((1 - idleAlpha) * delta + idleAlpha * learned)
        }

        offset = delta
        baseline = slow + delta
    }

    // MARK: - 退化模式（无慢层传感器，如 Intel Mac）

    private mutating func updateFallback(die: Double, isIdle: Bool) {
        if die < baseline {
            // 快速下修
            baseline += (die - baseline) * downAdjustmentRate
        } else if isIdle && isStable {
            // 慢速上调
            baseline += (die - baseline) * idleAlpha
        }
    }

    private func clampOffset(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }
}
