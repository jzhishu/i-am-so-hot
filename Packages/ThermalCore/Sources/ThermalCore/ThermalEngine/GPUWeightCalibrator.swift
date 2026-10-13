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
/// - gpuBusy ≥ 0.5：轻负载时 GPU 功耗被显示引擎固定开销 / 时钟门控主导，
///   不与 busy 成比例，野样本会系统性拉低 w_g（实测日常数据漂到 1.4
///   vs 压测真值 ~9.4），只信高负载样本
/// - cpuCores ≥ 2：CPU 负载太小时 cpuWatts 含固定空闲底噪（~0.5W），
///   按核数线性拆分会高估单核瓦数、低估 w_g
/// - 瞬时估值钳制在 [0.1, 2.0] × 核数，异常读数不污染 EMA
///
/// 收敛：EMA α=0.1（约 10 个有效样本达到权重 65%）。
/// 实测参考（2026-10-09，M2 Pro）：w_g ≈ 9.4（GPU 满载 ~13.5W / CPU ~1.44W 每核）。
public struct GPUWeightCalibrator: Sendable {

    /// 当前权重（EMA 平滑后）
    public private(set) var weight: Double
    /// CPU 每核满载瓦数估值（EMA，能耗对账用）。初值 1.5W（M2 Pro 实测 ~1.44W）
    public private(set) var wattsPerCore: Double
    /// 累计有效样本数（观测用）
    public private(set) var sampleCount = 0

    /// CPU 封装空闲底噪（W）：M2 Pro 实测 idle ~0.5W，
    /// 折算每核瓦数与能耗对账时都要先扣除
    public static let idleWattsFloor = 0.5

    private let alpha = 0.1
    /// GPU busy 护栏 0.5：轻负载时 GPU 功耗不与 busy 成比例
    /// （显示引擎固定开销 / 时钟门控），实测野样本会把 w_g 系统性拉低
    /// （2026-10-13 日常数据漂到 1.4 vs 压测真值 ~9.4），只信高负载样本
    private let minGPUBusy = 0.5
    private let minCPUCores = 2.0

    public init(initial: Double, initialWattsPerCore: Double = 1.5) {
        precondition(initial > 0, "w_g 初值必须为正数")
        self.weight = initial
        self.wattsPerCore = initialWattsPerCore
    }

    /// 注入一次设备级功耗 + 负载观测。样本不合格时不更新。
    public mutating func update(
        cpuWatts: Double,
        gpuWatts: Double,
        cpuCores: Double,
        gpuBusy: Double,
        coreCount: Int
    ) {
        guard coreCount > 0 else { return }

        // 每核瓦数：CPU 负载够就更新（独立于 GPU 护栏，纯 CPU 负载也能标定）。
        // 钳制 [0.3, 4.0]W：M 系单核实测 1~2W，留出机型差异余量。
        if cpuCores >= minCPUCores, cpuWatts > Self.idleWattsFloor {
            let sample = (cpuWatts - Self.idleWattsFloor) / cpuCores
            wattsPerCore = wattsPerCore * (1 - alpha) + min(max(sample, 0.3), 4.0) * alpha
        }

        guard gpuBusy >= minGPUBusy,
              cpuCores >= minCPUCores,
              cpuWatts > 0, gpuWatts > 0 else { return }

        let wattsPerCoreNow = cpuWatts / cpuCores
        let wattsFullGPU = gpuWatts / gpuBusy
        let estimate = wattsFullGPU / wattsPerCoreNow

        let clamped = min(max(estimate, 0.1 * Double(coreCount)), 2.0 * Double(coreCount))
        weight = weight * (1 - alpha) + clamped * alpha
        sampleCount += 1
    }
}
