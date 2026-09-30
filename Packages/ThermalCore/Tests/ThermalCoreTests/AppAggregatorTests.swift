import XCTest
@testable import ThermalCore

final class AppAggregatorTests: XCTestCase {

    private func sample(_ pid: pid_t, cpuDelta: TimeInterval) -> ProcessSample {
        ProcessSample(pid: pid, parentPid: 1, processName: "p\(pid)", cpuTimeDelta: cpuDelta)
    }

    // MARK: - Chrome 多进程聚合（PRD §7.1 核心场景）

    func testMultiProcessAppAggregatesIntoOne() {
        let samples = [
            sample(1, cpuDelta: 0.2),  // Chrome Main：0.2s / 1s = 20%
            sample(2, cpuDelta: 0.15), // Renderer
            sample(3, cpuDelta: 0.07), // GPU Process
        ]
        let result = AppAggregator.aggregate(samples: samples, interval: 1) { _ in
            ProcessOwnership(appID: "com.google.Chrome", confidence: 1, method: .sameBundle)
        }

        XCTAssertEqual(result.count, 1)
        let chrome = result["com.google.Chrome"]!
        XCTAssertEqual(chrome.processCount, 3)
        XCTAssertEqual(chrome.cpu, 0.42, accuracy: 1e-9)
    }

    func testDifferentAppsStaySeparate() {
        let samples = [sample(1, cpuDelta: 0.2), sample(2, cpuDelta: 0.1)]
        let result = AppAggregator.aggregate(samples: samples, interval: 2) { sample in
            sample.pid == 1
                ? ProcessOwnership(appID: "a", confidence: 1, method: .runningApplication)
                : ProcessOwnership(appID: "b", confidence: 1, method: .runningApplication)
        }
        XCTAssertEqual(result["a"]!.cpu, 0.1, accuracy: 1e-9) // 0.2s / 2s
        XCTAssertEqual(result["b"]!.cpu, 0.05, accuracy: 1e-9)
    }

    func testZeroIntervalReturnsEmpty() {
        let result = AppAggregator.aggregate(samples: [sample(1, cpuDelta: 1)], interval: 0) { _ in
            ProcessOwnership(appID: "a", confidence: 1, method: .runningApplication)
        }
        XCTAssertTrue(result.isEmpty)
    }
}
