import Foundation

/// 用户可识别的 App 身份（技术方案 §4.2）。
///
/// 用户看到的是 App（Chrome / Cursor），而不是进程（Helper / Renderer）。
public struct AppIdentity: Sendable, Equatable, Identifiable {
    /// 归属用的稳定 ID：普通 App 使用 bundleID；macOS / Other 使用保留 ID。
    public let id: String
    public let rootPid: pid_t?
    public let bundleID: String?
    public let localizedName: String
    public let bundlePath: String?
    public let executablePath: String?

    public init(
        id: String,
        rootPid: pid_t? = nil,
        bundleID: String? = nil,
        localizedName: String,
        bundlePath: String? = nil,
        executablePath: String? = nil
    ) {
        self.id = id
        self.rootPid = rootPid
        self.bundleID = bundleID
        self.localizedName = localizedName
        self.bundlePath = bundlePath
        self.executablePath = executablePath
    }
}

extension AppIdentity {
    /// 系统核心进程（kernel_task / launchd / WindowServer 等）统一归类为 macOS，
    /// 不提供 Quit（PRD §8.3）。
    public static let macOS = AppIdentity(id: "system.macos", localizedName: "macOS")

    /// 无法归属的进程兜底归类。
    public static let other = AppIdentity(id: "system.other", localizedName: "Other")
}
