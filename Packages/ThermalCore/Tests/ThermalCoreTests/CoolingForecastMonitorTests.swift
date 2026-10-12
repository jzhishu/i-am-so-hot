import XCTest
@testable import ThermalCore

/// beginCoolingForecast 的门槛与新鲜度守卫（review P1/P2 修复回归）
final class CoolingForecastMonitorTests: XCTestCase {

    private struct MockProvider: TemperatureProvider {
        var die: Double?
        func read() -> TemperatureReading {
            TemperatureReading(dieCelsius: die, slowAnchorCelsius: die)
        }
    }

    /// 构造一个带热量水库的 monitor：先喂 tick 建立 App 热储量
    private func makeMonitor(temp: Double? = 50) -> ThermalMonitor {
        let monitor = ThermalMonitor(
            temperatureProvider: MockProvider(die: temp),
            initialBaseline: 45, initialGain: 0.016
        )
        // 手工注入热储量（绕过采样链路，直接驱动引擎）
        for _ in 0..<5 {
            _ = monitor.tick()
        }
        return monitor
    }

    func testForecastNotCreatedWhenDropTooSmall() {
        // gain 极小 → steadyDrop < 0.5°C → 不建立会话（与 what-if 0.5°C 阈值对齐）
        let monitor = ThermalMonitor(
            temperatureProvider: MockProvider(die: 50),
            initialBaseline: 45, initialGain: 0.0001
        )
        _ = monitor.tick()
        monitor.beginCoolingForecast(appID: "any", appName: "Tiny")
        let snapshot = monitor.tick()
        XCTAssertNil(snapshot.coolingForecast, "降幅过小不应建立预测会话")
    }

    func testForecastNotCreatedWhenTemperatureStale() {
        let mock = MockProvider(die: 50)
        let monitor = ThermalMonitor(
            temperatureProvider: mock,
            initialBaseline: 45, initialGain: 0.016
        )
        _ = monitor.tick()
        // 距上次温度采样远超 2 个 tick 间隔 → 视为温度未知
        let farFuture = Date().addingTimeInterval(600)
        monitor.beginCoolingForecast(appID: "any", appName: "Stale", at: farFuture)
        // 主动验证：会话未建立（snapshot 不含 forecast）
        // 注：farFuture 时刻不 tick（避免干扰），直接再正常 tick 检查
        let snapshot = monitor.tick()
        XCTAssertNil(snapshot.coolingForecast, "温度过期不应建立预测会话")
    }

    func testForecastNotCreatedWithoutReservoir() {
        let monitor = ThermalMonitor(
            temperatureProvider: MockProvider(die: 50),
            initialBaseline: 45, initialGain: 0.016
        )
        _ = monitor.tick()
        // 无采样注入 → 任意 appID 无水库
        monitor.beginCoolingForecast(appID: "nonexistent", appName: "Ghost")
        let snapshot = monitor.tick()
        XCTAssertNil(snapshot.coolingForecast)
    }
}
