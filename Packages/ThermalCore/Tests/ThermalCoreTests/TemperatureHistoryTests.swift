import XCTest
@testable import ThermalCore

/// TemperatureHistory：三级降采样历史（v0.5，技术方案 §18）
final class TemperatureHistoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// 以固定间隔连录 n 个点，温度由 closure 决定
    private func record(
        _ history: inout TemperatureHistory,
        seconds: Int,
        interval: TimeInterval = 5,
        value: (Int) -> Double = { _ in 40 }
    ) {
        for i in 0..<seconds / Int(interval) {
            history.record(value(i), at: t0.addingTimeInterval(TimeInterval(i) * interval))
        }
    }

    // MARK: - raw 层

    func testRawSummaryBasic() {
        var h = TemperatureHistory()
        record(&h, seconds: 60, interval: 5, value: { 40 + Double($0) })  // 40...51
        let s = h.last5Minutes(now: t0.addingTimeInterval(60))
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.min, 40)
        XCTAssertEqual(s!.max, 51)
        XCTAssertEqual(s!.avg, 45.5, accuracy: 1e-9)
    }

    func testRawPrunedAfter5Minutes() {
        var h = TemperatureHistory()
        record(&h, seconds: 10, value: { _ in 50 })       // 旧数据 50°C
        record(&h, seconds: 10, value: { _ in 40 })       // 新数据 40°C
        // 时间推进到 10 分钟后：旧点应被剪掉
        let later = t0.addingTimeInterval(600)
        h.record(40, at: later)
        h.record(40, at: later.addingTimeInterval(5))
        let s = h.last5Minutes(now: later.addingTimeInterval(5))
        XCTAssertEqual(s!.max, 40, "5 分钟前的点不应留在 raw 层")
    }

    func testSummaryNilWithInsufficientData() {
        var h = TemperatureHistory()
        h.record(40, at: t0)
        XCTAssertNil(h.last5Minutes(now: t0), "单点不足以构成汇总")
    }

    // MARK: - tier2 滚聚

    func testTier2BucketClosesOnBoundaryCrossing() {
        var h = TemperatureHistory()
        // 录 2 分钟（每 5s 一点），跨越 4 个 30s 桶边界
        record(&h, seconds: 120, interval: 5, value: { _ in 42 })
        let now = t0.addingTimeInterval(120)
        h.record(42, at: now)
        // 已闭合的桶应进入 1h 汇总
        let s = h.lastHour(now: now)
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.avg, 42, accuracy: 1e-9)
    }

    func testTier2WeightedAverage() {
        var h = TemperatureHistory()
        // 第一个 30s 桶 40°C，第二个 30s 桶 50°C
        record(&h, seconds: 30, interval: 5, value: { _ in 40 })
        record(&h, seconds: 60, interval: 5, value: { i in
            i < 6 ? 40 : 50
        })
        let now = t0.addingTimeInterval(65)
        h.record(50, at: now)
        let s = h.lastHour(now: now)
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.min, 40)
        XCTAssertEqual(s!.max, 50)
    }

    // MARK: - tier3 滚聚与剪枝

    func testTier3RollsUpFromTier2() {
        var h = TemperatureHistory()
        // 录 10 分钟：前 5 分钟 40°C，后 5 分钟 50°C
        record(&h, seconds: 600, interval: 5, value: { i in i < 60 ? 40 : 50 })
        let now = t0.addingTimeInterval(600)
        h.record(50, at: now)
        let s = h.last24Hours(now: now)
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.min, 40)
        XCTAssertEqual(s!.max, 50)
        // 加权平均应接近 45（两桶点数相近）
        XCTAssertEqual(s!.avg, 45, accuracy: 1.0)
    }

    // MARK: - 持久化

    func testPersistenceRoundTrip() {
        var h = TemperatureHistory()
        record(&h, seconds: 600, interval: 5, value: { i in i < 60 ? 40 : 50 })
        let now = t0.addingTimeInterval(600)
        h.record(50, at: now)

        let persisted = h.export()
        let data = try! JSONEncoder().encode(persisted)
        let decoded = try! JSONDecoder().decode(TemperatureHistory.Persisted.self, from: data)

        let restored = TemperatureHistory(restoring: decoded, now: now)
        let s = restored.last24Hours(now: now)
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.min, 40)
        XCTAssertEqual(s!.max, 50)
    }

    func testRestorePrunesExpiredBuckets() {
        var h = TemperatureHistory()
        record(&h, seconds: 600, interval: 5, value: { _ in 42 })
        let persisted = h.export()
        // 25 小时后恢复：tier2（1h 窗口）应清空，tier3（24h 窗口）也应清空
        let dayLater = t0.addingTimeInterval(25 * 3600)
        let restored = TemperatureHistory(restoring: persisted, now: dayLater)
        XCTAssertNil(restored.lastHour(now: dayLater))
        XCTAssertNil(restored.last24Hours(now: dayLater))
    }
}
