import Foundation

/// 面板/App 层消费的 App 热量信息。
public struct AppHeatInfo: Sendable, Identifiable {
    public let id: String          // appID
    public let name: String
    public let bundlePath: String? // App 层用于查图标
    public let rootPid: pid_t?     // nil（macOS / Other）表示不可 Quit
    public let cpu: Double         // 核数口径，1.0 = 一个核满载
    public let gpu: Double         // v0.5，1.0 = GPU 全部执行单元满载
    public let processCount: Int
    public let heatShare: Double   // 0~1
    public let estimatedDeltaC: Double
    /// 瞬时功率估值（瓦）：(CPU + w_g×GPU) × wattsPerCore，缺口归因的 App 含缺口瓦数。
    /// 估算值，非实测（面板底部免责声明覆盖）
    public let watts: Double
    /// 系统 UI 组件（控制中心 / Dock / Finder 等）：不提供 Quit
    public let isSystemComponent: Bool

    /// 系统归类（macOS / Other）与系统 UI 组件不提供 Quit（PRD §8.3）
    public var canQuit: Bool { rootPid != nil && !isSystemComponent }

    public init(
        id: String, name: String, bundlePath: String?, rootPid: pid_t?,
        cpu: Double, gpu: Double = 0, processCount: Int, heatShare: Double, estimatedDeltaC: Double,
        isSystemComponent: Bool = false,
        watts: Double = 0
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.rootPid = rootPid
        self.cpu = cpu
        self.gpu = gpu
        self.processCount = processCount
        self.heatShare = heatShare
        self.estimatedDeltaC = estimatedDeltaC
        self.isSystemComponent = isSystemComponent
        self.watts = watts
    }
}

/// 进行中的降温预测会话快照（v0.8）：Quit 后一段时间内在面板顶部展示
public struct CoolingForecastInfo: Sendable, Equatable {
    public let appName: String
    /// 未来里程碑（相对当前时间的秒数 + 预期温度），已按时间升序
    public let milestones: [CoolingPrediction.Milestone]
    /// 稳态预期温度
    public let steadyCelsius: Double
    /// 稳态总降幅（低置信度文案分级用）
    public let steadyDrop: Double

    public init(appName: String, milestones: [CoolingPrediction.Milestone], steadyCelsius: Double, steadyDrop: Double) {
        self.appName = appName
        self.milestones = milestones
        self.steadyCelsius = steadyCelsius
        self.steadyDrop = steadyDrop
    }
}

/// 三窗口温度历史汇总（v0.5，§18）。窗口数据不足时对应字段为 nil。
public struct TemperatureHistorySummary: Sendable, Equatable {
    public let fiveMin: TemperatureHistory.Summary?
    public let oneHour: TemperatureHistory.Summary?
    public let twentyFourHours: TemperatureHistory.Summary?
    /// 最近 1 小时的 30s 桶序列（温度曲线用，时间升序）
    public let hourBuckets: [TemperatureHistory.Bucket]

    public var isEmpty: Bool {
        fiveMin == nil && oneHour == nil && twentyFourHours == nil && hourBuckets.isEmpty
    }

    public init(
        fiveMin: TemperatureHistory.Summary?,
        oneHour: TemperatureHistory.Summary?,
        twentyFourHours: TemperatureHistory.Summary?,
        hourBuckets: [TemperatureHistory.Bucket] = []
    ) {
        self.fiveMin = fiveMin
        self.oneHour = oneHour
        self.twentyFourHours = twentyFourHours
        self.hourBuckets = hourBuckets
    }
}

/// 一次 tick 的完整快照，UI 只消费它（技术方案 §19：UI 不触发重型采样）。
public struct MonitorSnapshot: Sendable {
    public let temperatureCelsius: Double?
    public let baselineCelsius: Double
    /// 0~1，1 = 全部核满载
    public let totalCPU: Double
    /// 0~1，1 = GPU 全部执行单元满载（v0.5，来自 AGX client 差分总量）
    public let totalGPU: Double
    public let thermalStateElevated: Bool
    public let mode: SamplingMode
    /// 按 heatShare 降序
    public let apps: [AppHeatInfo]
    /// 全部 App 的 +°C 合计（含未展示的长尾，用于底部汇总行）
    public let appsTotalDeltaC: Double
    /// 模型自检：B + Σ g·H_i（热模型 v2 §12.2），应与实测温度接近
    public let estimatedCelsius: Double?
    /// 三窗口温度历史（5min / 1h / 24h），冷启动初期各窗口可为 nil
    public let history: TemperatureHistorySummary?
    /// 进行中的降温预测（Quit 后展示），无会话或预测周期结束为 nil
    public let coolingForecast: CoolingForecastInfo?
    /// 预测置信度（v0.8）：low 时 UI 降级为模糊文案，不假精确
    public let predictionConfidence: CoolingPrediction.Confidence
    /// 摄像头正在采集（System Hardware 副标题标注用，仅缺口发生时采样）
    public let cameraActive: Bool
    /// 整机封装功耗（CPU + GPU 瓦数，实测；功耗计不可用时为 nil）
    public let totalWatts: Double?

    public init(
        temperatureCelsius: Double?,
        baselineCelsius: Double,
        totalCPU: Double,
        totalGPU: Double = 0,
        thermalStateElevated: Bool,
        mode: SamplingMode,
        apps: [AppHeatInfo],
        appsTotalDeltaC: Double,
        estimatedCelsius: Double?,
        history: TemperatureHistorySummary? = nil,
        coolingForecast: CoolingForecastInfo? = nil,
        predictionConfidence: CoolingPrediction.Confidence = .normal,
        cameraActive: Bool = false,
        totalWatts: Double? = nil
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.baselineCelsius = baselineCelsius
        self.totalCPU = totalCPU
        self.totalGPU = totalGPU
        self.thermalStateElevated = thermalStateElevated
        self.mode = mode
        self.apps = apps
        self.appsTotalDeltaC = appsTotalDeltaC
        self.estimatedCelsius = estimatedCelsius
        self.history = history
        self.coolingForecast = coolingForecast
        self.predictionConfidence = predictionConfidence
        self.cameraActive = cameraActive
        self.totalWatts = totalWatts
    }
}
