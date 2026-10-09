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
        // GPU busy < 0.2：泄漏/刷新噪声主导，不更新
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 10, gpuWatts: 5, cpuCores: 4, gpuBusy: 0.1, coreCount: cores)
        XCTAssertEqual(cal.weight, 6)
        XCTAssertEqual(cal.sampleCount, 0)
    }

    func testGuardRejectsLowCPULoad() {
        // CPU < 2 核：空闲底噪主导，不更新
        var cal = GPUWeightCalibrator(initial: 6)
        cal.update(cpuWatts: 1, gpuWatts: 10, cpuCores: 0.5, gpuBusy: 0.9, coreCount: cores)
        XCTAssertEqual(cal.weight, 6)
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
