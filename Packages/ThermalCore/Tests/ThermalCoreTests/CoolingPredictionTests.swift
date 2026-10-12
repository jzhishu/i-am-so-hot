import XCTest
@testable import ThermalCore

/// CoolingPrediction：v0.8 降温预测纯函数
final class CoolingPredictionTests: XCTestCase {

    /// 典型场景：fast=30, slow=20, g=0.02 → 稳态降幅 1.0°C，起始 50°C
    private func makePrediction(
        fast: Double = 30, slow: Double = 20,
        gain: Double = 0.02, start: Double = 50
    ) -> CoolingPrediction {
        CoolingPrediction(
            appName: "Chrome",
            fastHeat: fast, slowHeat: slow,
            gain: gain, tauFast: 15, tauSlow: 120,
            startCelsius: start,
            startTime: Date(timeIntervalSince1970: 1000)
        )
    }

    func testSteadyDropEqualsEstimatedDelta() {
        let p = makePrediction()
        XCTAssertEqual(p.steadyDrop, 0.02 * 50, accuracy: 1e-12)
    }

    func testDropMonotonicAndConverges() {
        let p = makePrediction()
        var prev = -1.0
        for t in stride(from: 0.0, through: 1200, by: 15) {
            let d = p.drop(after: t)
            XCTAssertGreaterThanOrEqual(d, prev, "降幅必须单调不减")
            prev = d
        }
        // 10×τslow 后应基本收敛到稳态
        XCTAssertEqual(p.drop(after: 1200), p.steadyDrop, accuracy: 0.01)
    }

    func testFastLayerDominatesEarlyDrop() {
        // fast 层（τ=15）在前 15s 应贡献大部分降幅
        let p = makePrediction(fast: 45, slow: 5, gain: 0.02)   // steady = 1.0
        let early = p.drop(after: 15)
        // 15s：fast 降 0.02×45×(1−e^−1)≈0.568，slow 降 0.02×5×(1−e^−0.125)≈0.012
        XCTAssertEqual(early, 0.58, accuracy: 0.02)
        XCTAssertGreaterThan(early / p.steadyDrop, 0.5, "前 15s 应完成过半降幅")
    }

    func testTimeToFractionInversion() {
        let p = makePrediction()
        let t50 = p.time(toFraction: 0.5)!
        XCTAssertEqual(p.drop(after: t50), p.steadyDrop * 0.5, accuracy: 1e-3)
        // 单调：80% 的时间晚于 50%
        XCTAssertGreaterThan(p.time(toFraction: 0.8)!, t50)
    }

    func testMilestonesAreInFutureAndSorted() {
        let p = makePrediction()
        let now = p.startTime.addingTimeInterval(5)
        let ms = p.milestones(now: now)!
        XCTAssertEqual(ms.count, 2)
        XCTAssertGreaterThan(ms[0].seconds, 0)
        XCTAssertLessThan(ms[0].celsius, p.startCelsius)
        XCTAssertLessThan(ms[1].celsius, ms[0].celsius, "后一个里程碑温度更低")
        XCTAssertGreaterThan(ms[1].seconds, ms[0].seconds)
    }

    func testMilestonesExpireWhenNearlyDone() {
        let p = makePrediction()
        // 很久以后：剩余降幅 < 0.3°C → 预测周期结束
        XCTAssertNil(p.milestones(now: p.startTime.addingTimeInterval(600)))
    }

    func testMilestonesDropPastOnes() {
        let p = makePrediction()
        // 越过 50% 里程碑后，只剩 80% 一个
        let t50 = p.time(toFraction: 0.5)!
        let ms = p.milestones(now: p.startTime.addingTimeInterval(t50 + 10))
        XCTAssertEqual(ms?.count, 1)
        XCTAssertEqual(ms!.first!.celsius, p.expectedCelsius(after: p.time(toFraction: 0.8)!), accuracy: 1e-9)
    }

    func testConfidenceThreshold() {
        XCTAssertEqual(CoolingPrediction.confidence(residualGap: 1.0), .normal)
        XCTAssertEqual(CoolingPrediction.confidence(residualGap: 5.0), .low)
        XCTAssertEqual(CoolingPrediction.confidence(residualGap: nil), .low)
    }

    func testClockRollbackDoesNotKillSession() {
        let p = makePrediction()
        // now < startTime：瞬时回拨应按起点处理，返回完整里程碑而非 nil
        let ms = p.milestones(now: p.startTime.addingTimeInterval(-60))
        XCTAssertNotNil(ms)
        XCTAssertEqual(ms!.count, 2)
    }

    func testZeroHeatYieldsEmptyMilestonesNotNil() {
        // gain=0 或全零热量：steadyDrop=0 → 剩余降幅 0 < 0.3 → nil（不建立会话的兜底）
        let p = makePrediction(fast: 0, slow: 0)
        XCTAssertEqual(p.steadyDrop, 0)
        XCTAssertNil(p.milestones(now: p.startTime))
    }
}
