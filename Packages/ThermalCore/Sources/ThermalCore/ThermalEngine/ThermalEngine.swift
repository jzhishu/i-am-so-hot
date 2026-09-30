import Foundation

/// 热引擎：Power Score → 热记忆水库 → Heat Share → Estimated +°C。
/// （技术方案 §8-§12）
///
/// 核心原则：
/// - 模型必须有热记忆：App CPU 降到 0，热量不应瞬间消失。
/// - 先做相对归因（Heat Share），再做绝对温度估算（Estimated +°C）。
///
/// 双时间常数水库（v0.5，技术方案 §9.3 / §13）：
///
///     H_fast(t) = H_fast(t-1) · e^(-Δt/τf) + ρ · P(t) · Δt       （芯片层）
///     H_slow(t) = H_slow(t-1) · e^(-Δt/τs) + (1−ρ) · P(t) · Δt   （机身层）
///     H = H_fast + H_slow
///
/// 物理动机（压测实测）：CPU 停止后 die 温度快速回落，但机身（chassis）
/// 散热远慢于单 τ=60 的预测——单时间常数无法同时拟合「升得快」和「散得慢」。
/// 快层 τ≈15s 拟合芯片响应，慢层 τ≈120s 拟合机身热容。
///
/// 稳态兼容性：H_ss = P × (ρ·τf + (1−ρ)·τs) = P × (0.6×15 + 0.4×120) ≈ 57P，
/// 与旧单 τ=60 的 60P 基本一致，已校准的 g 继续有效（微小差异由在线校准吸收）。
public struct ThermalEngine: Sendable {

    /// 快层时间常数（秒）：芯片级热量，响应快、消散快
    public var tauFast: Double
    /// 慢层时间常数（秒）：机身级热量，积累慢、散热慢
    public var tauSlow: Double
    /// 功率注入快层的比例（其余进慢层）
    public var fastSplit: Double

    /// appID -> 快层热储量
    private var fastReservoirs: [String: Double] = [:]
    /// appID -> 慢层热储量
    private var slowReservoirs: [String: Double] = [:]

    public init(tauFast: Double = 15, tauSlow: Double = 120, fastSplit: Double = 0.6) {
        precondition(tauFast > 0 && tauSlow > 0, "tau 必须为正数")
        precondition((0...1).contains(fastSplit), "fastSplit 必须在 0~1")
        self.tauFast = tauFast
        self.tauSlow = tauSlow
        self.fastSplit = fastSplit
    }

    /// 合成热储量（fast + slow），保持单水库语义供外部消费
    public var reservoirs: [String: Double] {
        var combined = slowReservoirs
        for (appID, h) in fastReservoirs {
            combined[appID, default: 0] += h
        }
        return combined
    }

    /// 注入一次采样：每个 App 的瞬时 Power Score。
    /// - Parameters:
    ///   - powerScores: appID -> P(t)
    ///   - deltaTime: 距上次采样的间隔（秒）
    public mutating func ingest(powerScores: [String: Double], deltaTime dt: TimeInterval) {
        precondition(dt > 0, "deltaTime 必须为正数")
        fastReservoirs = Self.evolve(
            fastReservoirs, powerScores: powerScores,
            decay: exp(-dt / tauFast), split: fastSplit, dt: dt
        )
        slowReservoirs = Self.evolve(
            slowReservoirs, powerScores: powerScores,
            decay: exp(-dt / tauSlow), split: 1 - fastSplit, dt: dt
        )
    }

    /// 单层水库演化：衰减 + 注入 + 新 App + 清理耗尽项
    private static func evolve(
        _ reservoirs: [String: Double],
        powerScores: [String: Double],
        decay: Double,
        split: Double,
        dt: TimeInterval
    ) -> [String: Double] {
        var next = reservoirs
        for (appID, h) in next {
            next[appID] = h * decay + (powerScores[appID] ?? 0) * split * dt
        }
        for (appID, p) in powerScores where next[appID] == nil {
            next[appID] = p * split * dt
        }
        // 清理热量已耗尽的 App，避免 reservoirs 无限增长
        return next.filter { $0.value > 1e-6 }
    }

    /// Heat Share：各 App 热储量占比（技术方案 §10），最可信指标。
    /// 总热储量为 0 时返回空字典。
    public func heatShares() -> [String: Double] {
        let all = reservoirs
        let total = all.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return all.mapValues { $0 / total }
    }

    /// Estimated +°C（热模型 v2，技术方案 §12.1）：
    ///
    ///     ΔT_i = g × H_i
    ///
    /// g 为设备级温升系数（°C / 单位热储量），离线拟合初值 + 在线校准（§14）。
    /// App 有热储量时贡献恒为正，不会在低温时全体塌缩为 0。
    public func estimatedDeltaCs(gain g: Double) -> [String: Double] {
        reservoirs.mapValues { $0 * g }
    }
}
