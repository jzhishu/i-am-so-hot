import AppKit
import ThermalCore

/// App 注册表：AppKit 层实现（技术方案 §4.2）。
///
/// - NSWorkspace.runningApplications → AppIdentity 列表，注入 ThermalCore.AppResolver。
/// - App 图标缓存（技术方案 §4.5：图标加载成本高，必须缓存）。
/// - Quit：NSRunningApplication.terminate()（PRD §8：优先正常退出，不强杀）。
final class RunningAppRegistry {

    private var iconCache: [String: NSImage] = [:]

    /// 当前运行的用户可识别 App（排除纯后台 prohibited 进程，
    /// 并经 AppRegistryMerger 归并嵌套 bundle 的 Helper）。
    func currentApps() -> [AppIdentity] {
        let identities: [AppIdentity] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited,
                  let bundleURL = app.bundleURL else { return nil }
            let id = app.bundleIdentifier ?? bundleURL.path
            // 图标直接用 NSRunningApplication.icon（比 icon(forFile:) 可靠），
            // 归并时按 appID 缓存
            if let nsIcon = app.icon {
                iconCache[id] = nsIcon
            }
            return AppIdentity(
                id: id,
                rootPid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
                    ?? bundleURL.deletingPathExtension().lastPathComponent,
                bundlePath: bundleURL.path,
                executablePath: app.executableURL?.path
            )
        }
        return AppRegistryMerger.merge(identities)
    }

    /// App 图标：优先注册时缓存的 NSRunningApplication.icon，
    /// 降级 NSWorkspace.icon(forFile:)（带缓存）
    func icon(appID: String, bundlePath: String?) -> NSImage? {
        if let cached = iconCache[appID] { return cached }
        guard let bundlePath else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        iconCache[appID] = icon
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
