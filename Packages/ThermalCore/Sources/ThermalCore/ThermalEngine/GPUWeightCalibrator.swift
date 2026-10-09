import Foundation

/// GPU 权重 w_g 在线标定器（v0.5 Device Calibration，技术方案 §8.2）。
///
/// 物理定义：GPU 满载 1 秒的发热 ≈ w_g 个 CPU 核满载 1 秒。
/// 用设备级实测功耗推导出瞬时估值：
///
///     w_g = (gpuWatts / gpuBusy) / (cpuWatts / cpuCores)
///
/// 其中 cpuCores 是同期 per-process CPU 差分总量（核数口径），
/// gpuBusy 是 GPU client 差分总量（1.0 = GPU 满载）。
///
/// 护栏（不满足则跳过本次样本，保持当前值）：
/// - gpuBusy ≥ 0.2：GPU 负载太小时功耗读数被泄漏/显示刷新噪声主导
/// - cpuCores ≥ 2：CPU 负载太小时 cpuWatts 含固定空闲底噪（~0.5W），
///   按核数线性拆分会高估单核瓦数、低估 w_g
/// - 瞬时估值钳制在 [0.1, 2.0] × 核数，异常读数不污染 EMA
///
/// 收敛：EMA α=0.1（约 10 个有效样本达到权重 65%）。
/// 实测参考（2026-10-09，M2 Pro）：w_g ≈ 9.4（GPU 满载 ~13.5W / CPU ~1.44W 每核）。
public struct GPUWeightCalibrator: Sendable {

    /// 当前权重（EMA 平滑后）
    public private(set) var weight: Double
    /// 累计有效样本数（观测用）
    public private(set) var sampleCount = 0

    private let alpha = 0.1
    private let minGPUBusy = 0.2
    private let minCPUCores = 2.0

    public init(initial: Double) {
        precondition(initial > 0, "w_g 初值必须为正数")
        self.weight = initial
    }

    /// 注入一次设备级功耗 + 负载观测。样本不合格时不更新。
    public mutating func update(
        cpuWatts: Double,
        gpuWatts: Double,
        cpuCores: Double,
        gpuBusy: Double,
        coreCount: Int
    ) {
        guard coreCount > 0,
              gpuBusy >= minGPUBusy,
              cpuCores >= minCPUCores,
              cpuWatts > 0, gpuWatts > 0 else { return }

        let wattsPerCore = cpuWatts / cpuCores
        let wattsFullGPU = gpuWatts / gpuBusy
        let estimate = wattsFullGPU / wattsPerCore

        let clamped = min(max(estimate, 0.1 * Double(coreCount)), 2.0 * Double(coreCount))
        weight = weight * (1 - alpha) + clamped * alpha
        sampleCount += 1
    }
}
