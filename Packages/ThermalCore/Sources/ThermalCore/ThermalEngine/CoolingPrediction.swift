import Foundation

/// 降温预测（v0.8 Prediction Preview，Roadmap §7 / 热模型 §9.3）。
///
/// 物理模型：App 被 Quit 后功率注入归零，其双层水库纯衰减：
///
///     H_i(t) = Hf·e^(−t/τf) + Hs·e^(−t/τs)
///     ΔT_drop(t) = g · (H_i(0) − H_i(t))
///     T_pred(t)  = T₀ − ΔT_drop(t)
///
/// 假设其余负载维持现状（短期近似成立；长期由在线校准吸收）。
///
/// 产品原则（Roadmap §7）：不能制造假精确——模型不稳定时降级为
/// 模糊文案（low confidence），由 UI 决定呈现精度。
public struct CoolingPrediction: Sendable, Equatable {

    /// 预测置信度：模型自检残差（|实测 − est|）过大时降级
    public enum Confidence: Sendable, Equatable {
        case normal   // 可显示整数温度
        case low      // 只显示模糊文案 / 范围
    }

    /// 一个里程碑：从现在起 seconds 秒后的预期温度
    public struct Milestone: Sendable, Equatable {
        public let seconds: TimeInterval
        public let celsius: Double
    }

    public let appName: String
    /// Quit 时刻的分层热储量
    public let fastHeat: Double
    public let slowHeat: Double
    /// 温升系数（°C / 单位热储量）
    public let gain: Double
    public let tauFast: Double
    public let tauSlow: Double
    /// Quit 时刻的实测温度
    public let startCelsius: Double
    /// Quit 时刻
    public let startTime: Date

    public init(
        appName: String,
        fastHeat: Double, slowHeat: Double,
        gain: Double, tauFast: Double, tauSlow: Double,
        startCelsius: Double, startTime: Date
    ) {
        self.appName = appName
        self.fastHeat = fastHeat
        self.slowHeat = slowHeat
        self.gain = gain
        self.tauFast = tauFast
        self.tauSlow = tauSlow
        self.startCelsius = startCelsius
        self.startTime = startTime
    }

    /// 稳态（t→∞）总降幅 = 该 App 当前的 Estimated +°C
    public var steadyDrop: Double { gain * (fastHeat + slowHeat) }

    /// t 秒后的累计降幅
    public func drop(after t: TimeInterval) -> Double {
        gain * (fastHeat * (1 - exp(-t / tauFast)) + slowHeat * (1 - exp(-t / tauSlow)))
    }

    /// t 秒后的预期温度
    public func expectedCelsius(after t: TimeInterval) -> Double {
        startCelsius - drop(after: t)
    }

    /// 达到稳态降幅指定比例所需时间（单调函数，二分反演）
    public func time(toFraction fraction: Double) -> TimeInterval? {
        let target = steadyDrop * fraction
        guard target > 0 else { return nil }
        var lo = 0.0, hi = max(tauFast, tauSlow) * 10   // 上界 10τ 必然足够
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if drop(after: mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// 面向 UI 的未来里程碑（相对 now）：
    /// 取稳态降幅 50% / 80% 两个点；已过去的里程碑自动剔除。
    /// 剩余降幅 < 0.3°C 视为预测周期结束（返回 nil）。
    public func milestones(now: Date) -> [Milestone]? {
        let elapsed = now.timeIntervalSince(startTime)
        guard elapsed >= 0, steadyDrop - drop(after: elapsed) >= 0.3 else { return nil }
        return [0.5, 0.8].compactMap { fraction in
            guard let t = time(toFraction: fraction), t > elapsed + 1 else { return nil }
            return Milestone(seconds: t - elapsed, celsius: expectedCelsius(after: t))
        }
    }

    /// 由模型自检残差推导置信度：|实测 − est| ≤ 2.5°C 视为可信
    public static func confidence(residualGap: Double?) -> Confidence {
        guard let gap = residualGap else { return .low }
        return abs(gap) <= 2.5 ? .normal : .low
    }
}
