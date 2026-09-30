import XCTest
@testable import ThermalCore

/// GainCalibrator 单元测试（热模型 v2 第三步，技术方案 §14）
final class GainCalibratorTests: XCTestCase {

    // MARK: - 收敛性

    func testConvergesToTrueGain() {
        var calibrator = GainCalibrator(initial: 0.016)
        let trueGain = 0.030
        let modelBaseline = 44.0
        var heat = 0.0

        // 模拟 4 核负载 10 分钟：H 按水库方程演化，T = baseline + g_true × H
        for _ in 0..<600 {
            heat = heat * exp(-1.0 / 60) + 4.0 * 1.0
            let temperature = modelBaseline + trueGain * heat
            calibrator.update(
                temperature: temperature,
                modelBaseline: modelBaseline,
                totalHeat: heat,
                totalCPU: 0.4,
                interval: 1.0
            )
        }

        XCTAssertEqual(calibrator.gain, trueGain, accuracy: 0.004,
                       "RLS 应收敛到真实 g")
    }

    func testConvergesAcrossLoadChanges() {
        var calibrator = GainCalibrator(initial: 0.016)
        let trueGain = 0.025
        let modelBaseline = 40.0
        var heat = 0.0
        // 负载在 2 / 6 / 10 核之间切换，模拟真实使用
        let loads = [2.0, 6.0, 10.0, 4.0]
        for (phase, load) in loads.enumerated() {
            for _ in 0..<300 {
                heat = heat * exp(-1.0 / 60) + load * 1.0
                let temperature = modelBaseline + trueGain * heat
                calibrator.update(
                    temperature: temperature,
                    modelBaseline: modelBaseline,
                    totalHeat: heat,
                    totalCPU: load / 10.0,
                    interval: 1.0
                )
            }
            _ = phase
        }
        XCTAssertEqual(calibrator.gain, trueGain, accuracy: 0.004)
    }

    // MARK: - 护栏

    func testNoUpdateWhenIdle() {
        var calibrator = GainCalibrator(initial: 0.016)
        // 怠速：totalCPU 低于阈值，即使温差很大也不回归（防除噪）
        let updated = calibrator.update(
            temperature: 60, modelBaseline: 40, totalHeat: 10, totalCPU: 0.01, interval: 1.0
        )
        XCTAssertFalse(updated)
        XCTAssertEqual(calibrator.gain, 0.016)
    }

    func testNoUpdateWhenHeatTooSmall() {
        var calibrator = GainCalibrator(initial: 0.016)
        let updated = calibrator.update(
            temperature: 60, modelBaseline: 40, totalHeat: 0.1, totalCPU: 0.5, interval: 1.0
        )
        XCTAssertFalse(updated)
        XCTAssertEqual(calibrator.gain, 0.016)
    }

    func testNoUpdateWithoutTemperature() {
        var calibrator = GainCalibrator(initial: 0.016)
        let updated = calibrator.update(
            temperature: nil, modelBaseline: 40, totalHeat: 100, totalCPU: 0.5, interval: 1.0
        )
        XCTAssertFalse(updated)
        XCTAssertEqual(calibrator.gain, 0.016)
    }

    // MARK: - 钳制

    func testGainClampedToBounds() {
        var calibrator = GainCalibrator(initial: 0.016)
        // 极端观测：温度远高于模型能解释的范围 → g 被钳在上界
        for _ in 0..<100 {
            calibrator.update(
                temperature: 120, modelBaseline: 40, totalHeat: 100, totalCPU: 0.9, interval: 1.0
            )
        }
        XCTAssertLessThanOrEqual(calibrator.gain, GainCalibrator.gainBounds.upperBound)
        XCTAssertGreaterThanOrEqual(calibrator.gain, GainCalibrator.gainBounds.lowerBound)
    }

    func testInitialGainClamped() {
        let tooHigh = GainCalibrator(initial: 1.0)
        XCTAssertEqual(tooHigh.gain, GainCalibrator.gainBounds.upperBound)
        let tooLow = GainCalibrator(initial: 0.0001)
        XCTAssertEqual(tooLow.gain, GainCalibrator.gainBounds.lowerBound)
    }
}
