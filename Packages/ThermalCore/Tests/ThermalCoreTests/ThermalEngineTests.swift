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

    // MARK: - Estimated +°C（技术方案 §12）

    func testEstimatedDeltaCs_distributeExcessHeat() {
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["chrome": 3, "cursor": 1], deltaTime: 1)

        // 78 - 50 = 28°C 额外温升，按 Share 分配：Chrome 21°C，Cursor 7°C
        let deltas = engine.estimatedDeltaCs(currentCelsius: 78, baselineCelsius: 50)
        XCTAssertEqual(deltas["chrome"]!, 21, accuracy: 1e-9)
        XCTAssertEqual(deltas["cursor"]!, 7, accuracy: 1e-9)
    }

    func testEstimatedDeltaCs_zeroWhenBelowBaseline() {
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["chrome": 10], deltaTime: 1)

        // 温度低于 baseline 时 ΔT = max(0, T - B) = 0
        let deltas = engine.estimatedDeltaCs(currentCelsius: 45, baselineCelsius: 50)
        XCTAssertEqual(deltas["chrome"]!, 0, accuracy: 1e-9)
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
