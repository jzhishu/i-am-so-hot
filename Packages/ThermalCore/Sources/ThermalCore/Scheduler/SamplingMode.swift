import Foundation

/// 自适应采样模式（PRD §10 / 技术方案 §6）。
///
/// 原则：默认低功耗，按需进入详细模式；关闭面板后自动降级。
public enum SamplingMode: String, Sendable, CaseIterable {
    /// 后台 idle：温度正常、面板关闭、负载低。只采总体 CPU / 温度 / thermalState。
    case sleep = "SLEEP"
    /// 温度升高或负载明显上升：启用详细进程采样与 App 级归因。
    case watch = "WATCH"
    /// 用户打开 Popover：App 排名与热模型 ~1Hz 更新。
    case live = "LIVE"

    /// 建议采样周期（秒）。温度等较昂贵指标可在此基础上按 N tick 降频。
    public var interval: TimeInterval {
        switch self {
        case .sleep: return 8   // 目标 5–10s
        case .watch: return 2.5 // 目标 2–3s
        case .live:  return 1   // 目标 ~1s
        }
    }

    /// 是否执行详细进程采样（per-process attribution）。
    public var collectsProcessDetails: Bool {
        switch self {
        case .sleep: return false
        case .watch, .live: return true
        }
    }
}

/// 采样模式状态机：根据面板状态与系统负载决定当前模式。
public struct SamplingModeController: Sendable {

    /// Total CPU 超过该值（0~1）视为负载明显升高，进入 WATCH。
    public var cpuWatchThreshold: Double = 0.30

    public private(set) var mode: SamplingMode = .sleep

    public init() {}

    /// 每次轻量采样后调用，更新模式。
    /// - Parameters:
    ///   - panelOpen: Popover 是否打开（最高优先级）
    ///   - totalCPU: 总体 CPU 使用率 0~1
    ///   - thermalStateElevated: thermalState 是否高于 nominal（fair/serious/critical）
    ///   - currentCelsius / baselineCelsius: 用于 dT 判断，暂以超 baseline +5°C 触发 WATCH
    public mutating func update(
        panelOpen: Bool,
        totalCPU: Double,
        thermalStateElevated: Bool,
        currentCelsius: Double? = nil,
        baselineCelsius: Double? = nil
    ) {
        if panelOpen {
            mode = .live
            return
        }
        let overheating: Bool
        if let current = currentCelsius, let baseline = baselineCelsius {
            overheating = current - baseline > 5
        } else {
            overheating = false
        }
        if thermalStateElevated || totalCPU >= cpuWatchThreshold || overheating {
            mode = .watch
        } else {
            mode = .sleep
        }
    }
}
