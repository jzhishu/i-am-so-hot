import Foundation

/// 热引擎：Power Score → 热记忆水库 → Heat Share → Estimated +°C。
/// （技术方案 §8-§12）
///
/// 核心原则：
/// - 模型必须有热记忆：App CPU 降到 0，热量不应瞬间消失。
/// - 先做相对归因（Heat Share），再做绝对温度估算（Estimated +°C）。
///
/// 单时间常数水库（v0.1 默认）：
///
///     H(t) = H(t-1) · e^(-Δt/τ) + P(t) · Δt
///
/// v0.5 计划升级为双时间常数（fast / slow reservoir）。
public struct ThermalEngine: Sendable {

    /// 散热时间常数（秒）。初始值仅用于起步，必须通过真实设备实验校准。
    /// 参考区间：τ_fast ≈ 10–20s，τ_slow ≈ 60–120s（技术方案 §9.3）。
    public var tau: Double

    /// appID -> 当前热储量 H
    public private(set) var reservoirs: [String: Double] = [:]

    public init(tau: Double = 60) {
        precondition(tau > 0, "tau 必须为正数")
        self.tau = tau
    }

    /// 注入一次采样：每个 App 的瞬时 Power Score（v0.1 简化为 CPU activity）。
    /// - Parameters:
    ///   - powerScores: appID -> P(t)
    ///   - deltaTime: 距上次采样的间隔（秒）
    public mutating func ingest(powerScores: [String: Double], deltaTime dt: TimeInterval) {
        precondition(dt > 0, "deltaTime 必须为正数")
        let decay = exp(-dt / tau)
        // 已存在的 App：衰减 + 注入
        for (appID, h) in reservoirs {
            reservoirs[appID] = h * decay + (powerScores[appID] ?? 0) * dt
        }
        // 新出现的 App：从零开始注入
        for (appID, p) in powerScores where reservoirs[appID] == nil {
            reservoirs[appID] = p * dt
        }
        // 清理热量已耗尽的 App，避免 reservoirs 无限增长
        reservoirs = reservoirs.filter { $0.value > 1e-6 }
    }

    /// Heat Share：各 App 热储量占比（技术方案 §10），首版最可信指标。
    /// 总热储量为 0 时返回空字典。
    public func heatShares() -> [String: Double] {
        let total = reservoirs.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return reservoirs.mapValues { $0 / total }
    }

    /// Estimated +°C（技术方案 §12）：
    ///
    ///     ΔT_i = (T_current - T_baseline) · Share_i
    ///
    /// 必须标注 Estimated，不是传感器实测值。
    public func estimatedDeltaCs(currentCelsius: Double, baselineCelsius: Double) -> [String: Double] {
        let deltaT = max(0, currentCelsius - baselineCelsius)
        return heatShares().mapValues { $0 * deltaT }
    }
}
