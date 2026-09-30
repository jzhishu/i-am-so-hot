import XCTest
@testable import ThermalCore

/// ThermalMonitor 的 SLEEP 水库回填逻辑（热模型 v2 修复：
/// SLEEP 期间 App 仍在运行，水库不能只衰减不补充）。
final class SleepRefillTests: XCTestCase {

    func testRefillDistributesTotalPowerByShares() {
        // totalCPU 0.5 × 10 核 = 5 核总功率，按 share 80/20 拆分
        let scores = ThermalMonitor.sleepRefillScores(
            totalCPU: 0.5,
            coreCount: 10,
            shares: ["a": 0.8, "b": 0.2]
        )
        XCTAssertEqual(scores["a"]!, 4.0, accuracy: 1e-9)
        XCTAssertEqual(scores["b"]!, 1.0, accuracy: 1e-9)
    }

    func testRefillKeepsReservoirAliveInSleep() {
        // 模拟日常场景：WATCH 建立分布后进入 SLEEP，
        // 回填应使 ΣH 维持在 P × τ 量级而不是衰减到 0
        var engine = ThermalEngine(tau: 60)
        engine.ingest(powerScores: ["chrome": 0.8, "macos": 0.2], deltaTime: 1)

        let totalCPU = 0.1 // 10 核 ≈ 1 核总功率（含后台）
        for _ in 0..<200 {
            let refill = ThermalMonitor.sleepRefillScores(
                totalCPU: totalCPU,
                coreCount: 10,
                shares: engine.heatShares()
            )
            engine.ingest(powerScores: refill, deltaTime: 8)
        }

        let sumH = engine.reservoirs.values.reduce(0, +)
        // 稳态 ΣH ≈ 1.0 核 × 60s = 60，不得衰减到接近 0
        XCTAssertEqual(sumH, 60, accuracy: 10)

        // 分布保持：chrome 仍占大头
        let shares = engine.heatShares()
        XCTAssertGreaterThan(shares["chrome"]!, shares["macos"]!)
    }

    func testRefillEmptyWhenNoPriorDistribution() {
        // 冷启动前水库为空：不臆造数据（由冷启动播种机制负责建立分布）
        let scores = ThermalMonitor.sleepRefillScores(totalCPU: 0.5, coreCount: 10, shares: [:])
        XCTAssertTrue(scores.isEmpty)
    }

    func testRefillEmptyWhenZeroLoad() {
        let scores = ThermalMonitor.sleepRefillScores(
            totalCPU: 0,
            coreCount: 10,
            shares: ["a": 1.0]
        )
        XCTAssertTrue(scores.isEmpty)
    }

    // MARK: - 微小份额蒸发（防止长尾 App 被回填永养）

    func testRefillEvictsTinySharesAndRenormalizes() {
        // tiny 仅 0.5% share，不参与回填；剩余归一化后 a 独占全部功率
        let scores = ThermalMonitor.sleepRefillScores(
            totalCPU: 0.2,
            coreCount: 10,
            shares: ["a": 0.495, "b": 0.5, "tiny": 0.005]
        )
        XCTAssertNil(scores["tiny"], "share < 1% 的 App 不应被回填续命")
        // a:b = 0.495:0.5 归一化，总功率 2 核
        XCTAssertEqual(scores["a"]!, 2.0 * 0.495 / 0.995, accuracy: 1e-9)
        XCTAssertEqual(scores["b"]!, 2.0 * 0.5 / 0.995, accuracy: 1e-9)
    }

    func testRefillEmptyWhenAllSharesTiny() {
        let scores = ThermalMonitor.sleepRefillScores(
            totalCPU: 0.2,
            coreCount: 10,
            shares: ["a": 0.004, "b": 0.003]
        )
        XCTAssertTrue(scores.isEmpty)
    }
}
