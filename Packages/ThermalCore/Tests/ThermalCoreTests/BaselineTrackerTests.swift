import XCTest
@testable import ThermalCore

/// 热模型 v2 Baseline 测试（技术方案 §11）。
final class BaselineTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 辅助：以固定间隔连续喂样本
    private func feed(
        _ tracker: inout BaselineTracker,
        die: Double, slow: Double?, isIdle: Bool,
        count: Int, stepSeconds: Double = 8
    ) {
        for i in 0..<count {
            tracker.update(
                die: die, slowAnchor: slow, isIdle: isIdle,
                now: t0.addingTimeInterval(Double(i) * stepSeconds)
            )
        }
    }

    // MARK: - 冷启动

    func testColdStartUsesFirstReading() {
        var tracker = BaselineTracker(initial: 45)
        tracker.update(die: 43.7, slowAnchor: nil, isIdle: false, now: t0)
        XCTAssertEqual(tracker.baseline, 43.7, accuracy: 1e-9)
        XCTAssertTrue(tracker.isInitialized)
    }

    // MARK: - 慢层锚点（§11.3）

    func testBaselineFollowsSlowAnchorPlusOffset() {
        var tracker = BaselineTracker(initial: 45)
        // die 43.3 / slow 34.0 → δ ≈ 9.3
        feed(&tracker, die: 43.3, slow: 34.0, isIdle: true, count: 5)
        XCTAssertNotNil(tracker.offset)
        XCTAssertEqual(tracker.offset!, 9.3, accuracy: 0.5)
        XCTAssertEqual(tracker.baseline, 43.3, accuracy: 0.5)
    }

    func testOffsetIsClamped() {
        var tracker = BaselineTracker(initial: 45)
        // die 与 slow 差 30°C（异常），δ 应被钳制到上限 15
        feed(&tracker, die: 64.0, slow: 34.0, isIdle: false, count: 3)
        XCTAssertEqual(tracker.offset!, 15, accuracy: 1e-9)
    }

    // MARK: - 不对称跟踪（§11.4）：baseline 不得持续高于当前温度

    func testBaselineTracksDownQuicklyWhenDieBelowBaseline() {
        var tracker = BaselineTracker(initial: 45)
        // 先在 45°C 环境学习
        feed(&tracker, die: 45, slow: 36, isIdle: true, count: 5)
        // 机器凉到 40°C（slow 同步降到 32）
        feed(&tracker, die: 40, slow: 32, isIdle: false, count: 10)
        XCTAssertLessThanOrEqual(
            tracker.baseline, 40.5,
            "die 低于 baseline 时，δ 应快速下修使 baseline 追上实测温度"
        )
    }

    // MARK: - 学习条件（§11.5）

    func testNoLearningWhenNotIdle() {
        var tracker = BaselineTracker(initial: 45)
        feed(&tracker, die: 43.3, slow: 34.0, isIdle: true, count: 5)
        let offsetBefore = tracker.offset!

        // 高负载：die 升高但 δ 不应被污染（温度也不稳定）
        feed(&tracker, die: 60, slow: 36, isIdle: false, count: 5, stepSeconds: 8)
        XCTAssertEqual(tracker.offset!, offsetBefore, accuracy: 1e-9,
                       "非 idle 时 δ 不得更新")
    }

    func testNoLearningWhenTemperatureUnstable() {
        var tracker = BaselineTracker(initial: 45)
        feed(&tracker, die: 43.3, slow: 34.0, isIdle: true, count: 5)
        let offsetBefore = tracker.offset!

        // idle 但温度在 baseline 之上剧烈波动（如负载刚结束的降温尾巴）：
        // die > B 不触发下修，此时 δ 不得被慢速学习污染
        let oscillating: [Double] = [46, 50, 47, 52, 49, 51, 48, 53, 50, 52]
        for (i, die) in oscillating.enumerated() {
            tracker.update(
                die: die, slowAnchor: 34, isIdle: true,
                now: t0.addingTimeInterval(1000 + Double(i) * 8)
            )
        }
        XCTAssertEqual(tracker.offset!, offsetBefore, accuracy: 1e-9,
                       "温度不稳定时 δ 不得更新（防降温尾巴污染）")
    }

    // MARK: - 退化模式（无慢层传感器）

    func testFallbackFastDownSlowUp() {
        var tracker = BaselineTracker(initial: 45)
        feed(&tracker, die: 45, slow: nil, isIdle: true, count: 3)

        // 快速下修
        feed(&tracker, die: 40, slow: nil, isIdle: false, count: 5)
        XCTAssertLessThan(tracker.baseline, 42)

        // 非 idle 不上调
        let b = tracker.baseline
        feed(&tracker, die: 50, slow: nil, isIdle: false, count: 5)
        XCTAssertEqual(tracker.baseline, b, accuracy: 1e-9)
    }

    // MARK: - 温度读取为 nil

    func testNilDieDoesNotUpdate() {
        var tracker = BaselineTracker(initial: 45)
        tracker.update(die: 44, slowAnchor: 34, isIdle: true, now: t0)
        let b = tracker.baseline
        tracker.update(die: nil, slowAnchor: 34, isIdle: true, now: t0.addingTimeInterval(8))
        XCTAssertEqual(tracker.baseline, b, accuracy: 1e-9)
    }
}

/// 传感器分类器测试（技术方案 §11.2）。
final class SensorClassifierTests: XCTestCase {

    private func sensor(_ name: String, _ c: Double) -> HIDTemperatureSensor {
        HIDTemperatureSensor(name: name, celsius: c)
    }

    /// 本机实测传感器形态
    private let sample: [HIDTemperatureSensor] = [
        .init(name: "PMU tdev8", celsius: 35.1),
        .init(name: "gas gauge battery", celsius: 33.0),
        .init(name: "PMU tdie2", celsius: 43.8),
        .init(name: "PMU tcal", celsius: 51.9),
        .init(name: "PMU tdie0", celsius: 42.4),
        .init(name: "PMU tdev3", celsius: 34.0),
        .init(name: "PMU TP0s", celsius: 43.1),
    ]

    func testDieMaxPicksDieSensors() {
        XCTAssertEqual(SensorClassifier.dieMax(sample)!, 43.8, accuracy: 1e-9)
    }

    func testSlowAnchorPicksLowestNonDieNonTcal() {
        // battery 33.0 < tdev3 34.0 < tdev8 35.1；die 与 tcal 不参与
        XCTAssertEqual(SensorClassifier.slowAnchor(sample)!, 33.0, accuracy: 1e-9)
    }

    func testSlowAnchorNilWhenAllDie() {
        let onlyDie = [sensor("PMU tdie0", 43), sensor("PMU tdie1", 44)]
        XCTAssertNil(SensorClassifier.slowAnchor(onlyDie))
    }

    func testDieMaxFallsBackToMaxWhenNoDie() {
        let noDie = [sensor("gas gauge battery", 33), sensor("PMU tdev1", 39)]
        XCTAssertEqual(SensorClassifier.dieMax(noDie)!, 39, accuracy: 1e-9)
    }

    func testEmptySensors() {
        XCTAssertNil(SensorClassifier.dieMax([]))
        XCTAssertNil(SensorClassifier.slowAnchor([]))
    }
}
