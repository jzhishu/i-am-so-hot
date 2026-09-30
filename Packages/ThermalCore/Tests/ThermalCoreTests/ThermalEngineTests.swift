import XCTest
@testable import ThermalCore

final class ThermalEngineTests: XCTestCase {

    // MARK: - 热记忆：App CPU 降到 0，热量不应瞬间消失（技术方案 §9.1）

    func testHeatReservoir_decaysGraduallyAfterLoadStops() {
        var engine = ThermalEngine(tau: 60)

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
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["chrome": 38, "cursor": 21, "docker": 11], deltaTime: 1)

        let shares = engine.heatShares()
        XCTAssertEqual(shares.values.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testHeatShares_proportionalToPower() {
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["a": 2, "b": 1], deltaTime: 1)

        let shares = engine.heatShares()
        XCTAssertEqual(shares["a"]!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(shares["b"]!, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testHeatShares_emptyWhenNoHeat() {
        let engine = ThermalEngine(tau: 60)
        XCTAssertTrue(engine.heatShares().isEmpty)
    }

    // MARK: - Estimated +°C（热模型 v2 §12.1：ΔT_i = g × H_i）

    func testEstimatedDeltaCs_proportionalToReservoir() {
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["chrome": 3, "cursor": 1], deltaTime: 1)

        // H_chrome = 3，H_cursor = 1（dt=1），g = 0.016
        let deltas = engine.estimatedDeltaCs(gain: 0.016)
        XCTAssertEqual(deltas["chrome"]!, 0.048, accuracy: 1e-9)
        XCTAssertEqual(deltas["cursor"]!, 0.016, accuracy: 1e-9)
    }

    func testEstimatedDeltaCs_neverCollapsesToZero() {
        var engine = ThermalEngine(tau: 60)
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
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["chrome": 10], deltaTime: 1)
        let d1 = engine.estimatedDeltaCs(gain: 0.01)["chrome"]!
        let d2 = engine.estimatedDeltaCs(gain: 0.02)["chrome"]!
        XCTAssertEqual(d2 / d1, 2.0, accuracy: 1e-9)
    }

    // MARK: - 资源清理

    func testReservoirs_evictDepletedApps() {
        var engine = ThermalEngine(tau: 1)
        engine.ingest(powerScores: ["chrome": 1e-3], deltaTime: 1)

        // τ = 1s，30 秒后热量应耗尽并被清理
        engine.ingest(powerScores: [:], deltaTime: 30)
        XCTAssertNil(engine.reservoirs["chrome"])
    }
}
