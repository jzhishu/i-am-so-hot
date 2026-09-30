import XCTest
@testable import ThermalCore

final class ThermalEngineTests: XCTestCase {

    // MARK: - 热记忆：App CPU 降到 0，热量不应瞬间消失（技术方案 §9.1）

    func testHeatReservoir_decaysGraduallyAfterLoadStops() {
        var engine = ThermalEngine()

        // Chrome 以 40 power 持续 10 秒
        for _ in 0..<10 {
            engine.ingest(powerScores: ["chrome": 40], deltaTime: 1)
        }
        let hotReservoir = engine.reservoirs["chrome"]!
        XCTAssertGreaterThan(hotReservoir, 0)

        // Chrome 停止工作 1 秒后：热量仍保留大部分（e^(-1/60) ≈ 0.983）
        engine.ingest(powerScores: [:], deltaTime: 1)
        let afterOneSecond = engine.reservoirs["chrome"]!
        XCTAssertGreaterThan(afterOneSecond, hotReservoir * 0.9)
        XCTAssertLessThan(afterOneSecond, hotReservoir)
    }

    // MARK: - Heat Share：归一化（技术方案 §10）

    func testHeatShares_sumToOne() {
        var engine = ThermalEngine()
        engine.ingest(powerScores: ["chrome": 38, "cursor": 21, "docker": 11], deltaTime: 1)

        let shares = engine.heatShares()
        XCTAssertEqual(shares.values.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testHeatShares_proportionalToPower() {
        var engine = ThermalEngine()
        engine.ingest(powerScores: ["a": 2, "b": 1], deltaTime: 1)

        let shares = engine.heatShares()
        XCTAssertEqual(shares["a"]!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(shares["b"]!, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testHeatShares_emptyWhenNoHeat() {
        let engine = ThermalEngine()
        XCTAssertTrue(engine.heatShares().isEmpty)
    }

    // MARK: - Estimated +°C（热模型 v2 §12.1：ΔT_i = g × H_i）

    func testEstimatedDeltaCs_proportionalToReservoir() {
        var engine = ThermalEngine()
        engine.ingest(powerScores: ["chrome": 3, "cursor": 1], deltaTime: 1)

        // H_chrome = 3，H_cursor = 1（dt=1），g = 0.016
        let deltas = engine.estimatedDeltaCs(gain: 0.016)
        XCTAssertEqual(deltas["chrome"]!, 0.048, accuracy: 1e-9)
        XCTAssertEqual(deltas["cursor"]!, 0.016, accuracy: 1e-9)
    }

    func testEstimatedDeltaCs_neverCollapsesToZero() {
        var engine = ThermalEngine()
        // App 刚停止工作：瞬时 power = 0，但热储量未衰减完。
        // v1 公式在 T ≤ baseline 时全体塌缩为 0；v2 只要有 H 就恒为正。
        for _ in 0..<10 {
            engine.ingest(powerScores: ["chrome": 40], deltaTime: 1)
        }
        engine.ingest(powerScores: [:], deltaTime: 1)

        let deltas = engine.estimatedDeltaCs(gain: 0.016)
        XCTAssertGreaterThan(deltas["chrome"]!, 0, "App 停止后热贡献应随水库衰减而不是瞬间归零")
    }

    func testEstimatedDeltaCs_scalesWithGain() {
        var engine = ThermalEngine()
        engine.ingest(powerScores: ["chrome": 10], deltaTime: 1)
        let d1 = engine.estimatedDeltaCs(gain: 0.01)["chrome"]!
        let d2 = engine.estimatedDeltaCs(gain: 0.02)["chrome"]!
        XCTAssertEqual(d2 / d1, 2.0, accuracy: 1e-9)
    }

    // MARK: - 资源清理

    func testReservoirs_evictDepletedApps() {
        var engine = ThermalEngine(tauFast: 1, tauSlow: 1)
        engine.ingest(powerScores: ["chrome": 1e-3], deltaTime: 1)

        // τ = 1s，30 秒后热量应耗尽并被清理
        engine.ingest(powerScores: [:], deltaTime: 30)
        XCTAssertNil(engine.reservoirs["chrome"])
    }

    // MARK: - 双时间常数（v0.5，技术方案 §9.3）

    /// 衰减形状：负载停止后「先快后慢」——快层迅速蒸发，慢层拖长尾。
    /// 单时间常数的衰减速率恒定，双层结构必须呈现速率下降。
    func testDualTau_decayIsFastThenSlow() {
        var engine = ThermalEngine(tauFast: 15, tauSlow: 120, fastSplit: 0.6)
        // 持续负载 120 秒，让两层都充分蓄水
        for _ in 0..<120 {
            engine.ingest(powerScores: ["chrome": 4], deltaTime: 1)
        }
        let total0 = engine.reservoirs["chrome"]!

        // 停止后前 10 秒的衰减速率
        var h = total0
        for _ in 0..<10 {
            engine.ingest(powerScores: [:], deltaTime: 1)
        }
        let earlyRate = (h - engine.reservoirs["chrome"]!) / 10 / h
        h = engine.reservoirs["chrome"]!

        // 60~70 秒处的衰减速率
        for _ in 0..<50 {
            engine.ingest(powerScores: [:], deltaTime: 1)
        }
        let before = engine.reservoirs["chrome"]!
        for _ in 0..<10 {
            engine.ingest(powerScores: [:], deltaTime: 1)
        }
        let lateRate = (before - engine.reservoirs["chrome"]!) / 10 / before

        XCTAssertGreaterThan(earlyRate, lateRate * 1.5,
                             "双层水库衰减应先快后慢：早期 \(earlyRate)，后期 \(lateRate)")
        // 70 秒后仍有显著残余（机身还热）——单 τ=60 此时只剩 e^(−70/60) ≈ 31%
        XCTAssertGreaterThan(engine.reservoirs["chrome"]! / total0, 0.31)
    }

    /// 稳态量级兼容：H_ss ≈ P × (ρ·τf + (1−ρ)·τs) = 0.6×15 + 0.4×120 = 57
    /// 与旧单 τ=60 的稳态 60P 基本一致（已校准的 g 继续有效）
    func testDualTau_steadyStateMagnitude() {
        var engine = ThermalEngine(tauFast: 15, tauSlow: 120, fastSplit: 0.6)
        // 持续负载 600 秒（5 倍慢层 τ），达到稳态
        for _ in 0..<600 {
            engine.ingest(powerScores: ["chrome": 2], deltaTime: 1)
        }
        let steadyState = engine.reservoirs["chrome"]!
        XCTAssertEqual(steadyState, 2 * (0.6 * 15 + 0.4 * 120), accuracy: 2.0,
                       "稳态热储量 ≈ P × 57")
    }

    /// 短促负载几乎只进快层：3 秒突发在 30 秒后基本消失（机身来不及热）
    func testDualTau_shortBurstMostlyVanishes() {
        var engine = ThermalEngine(tauFast: 15, tauSlow: 120, fastSplit: 0.6)
        for _ in 0..<3 {
            engine.ingest(powerScores: ["burst": 8], deltaTime: 1)
        }
        let peak = engine.reservoirs["burst"]!
        for _ in 0..<30 {
            engine.ingest(powerScores: [:], deltaTime: 1)
        }
        let remaining = engine.reservoirs["burst"]! / peak
        // 快层 30s 后剩 e^(−2) ≈ 13.5%，慢层剩 e^(−0.25) ≈ 78%，
        // 但短突发主要蓄在快层 → 综合剩余应显著低于单 τ=60 的 61%
        XCTAssertLessThan(remaining, 0.5)
        XCTAssertGreaterThan(remaining, 0.1)
    }
}
