import XCTest
@testable import ThermalCore

/// GPUSampler 纯函数测试（IOKit 枚举部分依赖真机，由 thermalprobe 验证）。
final class GPUSamplerTests: XCTestCase {

    // MARK: - parsePID

    func testParsePID_standardFormat() {
        XCTAssertEqual(GPUSampler.parsePID(from: "pid 165, WindowServer"), 165)
    }

    func testParsePID_processNameWithComma() {
        // 进程名含逗号：只取第一个逗号前的数字
        XCTAssertEqual(GPUSampler.parsePID(from: "pid 1234, Company, Inc. App"), 1234)
    }

    func testParsePID_invalidFormats() {
        XCTAssertNil(GPUSampler.parsePID(from: nil))
        XCTAssertNil(GPUSampler.parsePID(from: ""))
        XCTAssertNil(GPUSampler.parsePID(from: "WindowServer"))
        XCTAssertNil(GPUSampler.parsePID(from: "pid abc, foo"))
        XCTAssertNil(GPUSampler.parsePID(from: "pid , foo"))
        XCTAssertNil(GPUSampler.parsePID(from: "pid -1, foo"))
        XCTAssertNil(GPUSampler.parsePID(from: "pid 0, kernel_task"))
    }

    // MARK: - sumAppUsage

    func testSumAppUsage_multipleCommandQueues() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 3_000_000_000)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 86_462_166)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 0)],
        ]
        XCTAssertEqual(GPUSampler.sumAppUsage(usage), 3_086_462_166)
    }

    func testSumAppUsage_invalidInputs() {
        XCTAssertEqual(GPUSampler.sumAppUsage(nil), 0)
        XCTAssertEqual(GPUSampler.sumAppUsage("not an array"), 0)
        XCTAssertEqual(GPUSampler.sumAppUsage([[String: Any]]()), 0)
        XCTAssertEqual(GPUSampler.sumAppUsage([["API": "Metal"]]), 0)  // 缺 accumulatedGPUTime
    }

    // MARK: - deltas（纯函数差分）

    func testDeltas_basicIncrement() {
        let deltas = GPUSampler.deltas(
            current: [100: 3_000_000_000],
            previous: [100: 1_000_000_000]
        )
        XCTAssertEqual(deltas[100]!, 2.0, accuracy: 1e-9)
    }

    func testDeltas_newClientEstablishesBaseline() {
        // 新出现的 pid：无增量（防止把进程历史累计当成当前窗口增量）
        let deltas = GPUSampler.deltas(current: [100: 5_000_000_000], previous: [:])
        XCTAssertNil(deltas[100])
    }

    func testDeltas_counterRegressionClamped() {
        // client 重建 / PID reuse：累计值回退 → 钳 0（不产出增量）
        let deltas = GPUSampler.deltas(
            current: [100: 1_000_000_000],
            previous: [100: 9_000_000_000]
        )
        XCTAssertNil(deltas[100])
    }

    func testDeltas_disappearedPidDropped() {
        // 进程退出：不在 current 中，自然无增量；previous 由调用方整体替换
        let deltas = GPUSampler.deltas(current: [:], previous: [100: 5_000_000_000])
        XCTAssertTrue(deltas.isEmpty)
    }

    func testDeltas_zeroDeltaExcluded() {
        let deltas = GPUSampler.deltas(current: [100: 5], previous: [100: 5])
        XCTAssertNil(deltas[100])
    }
}
