import XCTest
@testable import ThermalCore

/// GPUWeightCalibrator：w_g 在线标定（v0.5 Device Calibration）
final class GPUWeightCalibratorTests: XCTestCase {

    private let cores = 12

    func testConvergesToPhysicalRatio() {
        // M2 Pro 实测口径：GPU 满载 13.5W / CPU 1.44W 每核 ≈ 9.4
        var cal = GPUWeightCalibrator(initial: 6)
        for _ in 0..<50 {
            cal.update(
                cpuWatts: 1.44 * 4,   // 4 核负载 5.76W
                gpuWatts: 13.5 * 0.8, // GPU busy 0.8 时 10.8W
                cpuCores: 4,
                gpuBusy: 0.8,
                coreCount: cores
            )
        }
        XCTAssertEqual(cal.weight, 13.5 / 1.44, accuracy: 0.2)
        XCTAssertEqual(cal.sampleCount, 50)
    }

    func testGuardRejectsLowGPULoad() {
        // GPU busy < 0.5：固定开销主导，功耗不与 busy 成比例，不更新
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 10, gpuWatts: 5, cpuCores: 4, gpuBusy: 0.3, coreCount: cores)
        XCTAssertEqual(cal.weight, 6)
        XCTAssertEqual(cal.sampleCount, 0)
    }

    func testGuardRejectsLowCPULoad() {
        // CPU < 2 核：空闲底噪主导，不更新
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 1, gpuWatts: 10, cpuCores: 0.5, gpuBusy: 0.9, coreCount: cores)
        XCTAssertEqual(cal.weight, 6)
    }

    // 每核瓦数标定（能耗对账用，v0.8+）
    func testWattsPerCoreUpdatesOnCPUOnlyLoad() {
        var cal = GPUWeightCalibrator(initial: 6)
        // 纯 CPU 负载（GPU busy=0，w_g 护栏不通过）：8 核 12.5W → (12.5−0.5)/8 = 1.5W/核
        for _ in 0..<30 {
            cal.update(cpuWatts: 12.5, gpuWatts: 0, cpuCores: 8, gpuBusy: 0, coreCount: cores)
        }
        XCTAssertEqual(cal.wattsPerCore, 1.5, accuracy: 0.01)
        XCTAssertEqual(cal.sampleCount, 0, "GPU 护栏未过，w_g 不应更新")
    }

    func testWattsPerCoreClampsOutliers() {
        var cal = GPUWeightCalibrator(initial: 6)
        // 异常读数：2 核 100W → 49.75W/核，应钳到 4.0 后 EMA 一步
        cal.update(cpuWatts: 100, gpuWatts: 0, cpuCores: 2, gpuBusy: 0, coreCount: cores)
        XCTAssertEqual(cal.wattsPerCore, 1.5 * 0.9 + 4.0 * 0.1, accuracy: 1e-9)
    }

    func testGuardRejectsInvalidReadings() {
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 0, gpuWatts: 10, cpuCores: 4, gpuBusy: 0.9, coreCount: cores)
        cal.update(cpuWatts: 10, gpuWatts: -1, cpuCores: 4, gpuBusy: 0.9, coreCount: cores)
        XCTAssertEqual(cal.weight, 6)
        XCTAssertEqual(cal.sampleCount, 0)
    }

    func testOutlierClamped() {
        // 异常读数（瞬时估值 100）被钳制在 2×核数，EMA 只被拉动一步
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 0.144 * 4, gpuWatts: 14.4 * 0.9, cpuCores: 4, gpuBusy: 0.9, coreCount: cores)
        // 估值 100 钳到 24，EMA: 6×0.9 + 24×0.1 = 7.8
        XCTAssertEqual(cal.weight, 7.8, accuracy: 1e-9)
    }

    func testEMAConvergesGradually() {
        // 单个样本不能把权重拉到位（α=0.1）
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 1.44 * 4, gpuWatts: 13.5 * 0.8, cpuCores: 4, gpuBusy: 0.8, coreCount: cores)
        XCTAssertEqual(cal.weight, 6 * 0.9 + 9.375 * 0.1, accuracy: 1e-9)
    }
}
