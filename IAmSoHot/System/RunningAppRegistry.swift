import AppKit
import ThermalCore

/// App 注册表：AppKit 层实现（技术方案 §4.2）。
///
/// - NSWorkspace.runningApplications → AppIdentity 列表，注入 ThermalCore.AppResolver。
/// - App 图标缓存（技术方案 §4.5：图标加载成本高，必须缓存）。
/// - Quit：NSRunningApplication.terminate()（PRD §8：优先正常退出，不强杀）。
final class RunningAppRegistry {

    private var iconCache: [String: NSImage] = [:]

    /// 当前运行的用户可识别 App（排除纯后台 prohibited 进程）。
    func currentApps() -> [AppIdentity] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited,
                  let bundleURL = app.bundleURL else { return nil }
            return AppIdentity(
                id: app.bundleIdentifier ?? bundleURL.path,
                rootPid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
                    ?? bundleURL.deletingPathExtension().lastPathComponent,
                bundlePath: bundleURL.path,
                executablePath: app.executableURL?.path
            )
        }
    }

    /// App 图标（带缓存，bundlePath 为 nil 时返回 nil）
    func icon(bundlePath: String?) -> NSImage? {
        guard let bundlePath else { return nil }
        if let cached = iconCache[bundlePath] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        iconCache[bundlePath] = icon
        return icon
    }

    /// 正常退出 App。返回是否成功发出退出请求。
    @discardableResult
    func terminate(rootPid: pid_t?) -> Bool {
        guard let rootPid,
              let app = NSRunningApplication(processIdentifier: rootPid) else { return false }
        return app.terminate()
    }
}
