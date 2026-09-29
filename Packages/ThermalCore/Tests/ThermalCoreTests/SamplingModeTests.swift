import XCTest
@testable import ThermalCore

final class SamplingModeControllerTests: XCTestCase {

    // MARK: - 模式切换（PRD §10）

    func testDefaultModeIsSleep() {
        let controller = SamplingModeController()
        XCTAssertEqual(controller.mode, .sleep)
    }

    func testPanelOpenForcesLive() {
        var controller = SamplingModeController()
        controller.update(panelOpen: true, totalCPU: 0.01, thermalStateElevated: false)
        XCTAssertEqual(controller.mode, .live)
    }

    func testHighCPUEscalatesToWatch() {
        var controller = SamplingModeController()
        controller.update(panelOpen: false, totalCPU: 0.5, thermalStateElevated: false)
        XCTAssertEqual(controller.mode, .watch)
    }

    func testElevatedThermalStateEscalatesToWatch() {
        var controller = SamplingModeController()
        controller.update(panelOpen: false, totalCPU: 0.05, thermalStateElevated: true)
        XCTAssertEqual(controller.mode, .watch)
    }

    func testTemperatureAboveBaselineEscalatesToWatch() {
        var controller = SamplingModeController()
        controller.update(
            panelOpen: false,
            totalCPU: 0.05,
            thermalStateElevated: false,
            currentCelsius: 62,
            baselineCelsius: 50
        )
        XCTAssertEqual(controller.mode, .watch)
    }

    func testPanelCloseDegradesToSleep() {
        var controller = SamplingModeController()
        controller.update(panelOpen: true, totalCPU: 0.01, thermalStateElevated: false)
        XCTAssertEqual(controller.mode, .live)

        controller.update(panelOpen: false, totalCPU: 0.01, thermalStateElevated: false)
        XCTAssertEqual(controller.mode, .sleep)
    }

    // MARK: - 采样周期与成本（技术方案 §6）

    func testIntervalsOrderedByCost() {
        XCTAssertLessThan(SamplingMode.live.interval, SamplingMode.watch.interval)
        XCTAssertLessThan(SamplingMode.watch.interval, SamplingMode.sleep.interval)
    }

    func testSleepSkipsProcessDetails() {
        XCTAssertFalse(SamplingMode.sleep.collectsProcessDetails)
        XCTAssertTrue(SamplingMode.watch.collectsProcessDetails)
        XCTAssertTrue(SamplingMode.live.collectsProcessDetails)
    }
}
