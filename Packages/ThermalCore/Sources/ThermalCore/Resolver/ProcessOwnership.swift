import Foundation

/// 进程归属结果（技术方案 §4.4）。
public struct ProcessOwnership: Sendable, Equatable {
    public let appID: String
    /// 0.0 ~ 1.0，用于 Debug 与错误分析，默认 UI 不展示（Roadmap v0.2）。
    public let confidence: Double
    public let method: OwnershipMethod

    public init(appID: String, confidence: Double, method: OwnershipMethod) {
        self.appID = appID
        self.confidence = confidence
        self.method = method
    }
}

/// 归属方法，对应技术方案 §4.3 的匹配优先级。
public enum OwnershipMethod: String, Sendable {
    /// 1. PID 直接对应已知 NSRunningApplication
    case runningApplication
    /// 2. executable path 位于某 .app Bundle 内
    case sameBundle
    /// 3. 沿 PPID 向上追溯到可识别 App
    case ancestor
    /// 4. responsible PID / process coalition
    case responsiblePID
    /// 5. 已知 helper / framework 规则
    case helperRule
    /// 6. 系统进程规则
    case systemRule
    /// 7. Unknown / Background Process
    case unknown
}
