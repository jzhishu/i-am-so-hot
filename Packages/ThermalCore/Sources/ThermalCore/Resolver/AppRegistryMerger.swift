import Foundation

/// App 注册表归并器（技术方案 §4.2 / PRD §4.1）。
///
/// 背景：Electron 类 App 的 Helper 会以**独立 bundleID** 注册为
/// NSRunningApplication（如 `Cursor Helper (Plugin).app` 位于
/// `Cursor.app/Contents/Frameworks/` 内）。若注册表不去重，归属优先级
/// 第 1 条（PID 直查）会让 Helper 作为独立 App 泄漏到 UI，
/// 违反「面向用户，而不是面向进程」的核心原则。
///
/// 规则：bundlePath 嵌套在另一个 App 的 .app bundle 内的，归并掉
///（其进程后续会经 sameBundle 匹配归入主 App）。
public enum AppRegistryMerger {

    public static func merge(_ apps: [AppIdentity]) -> [AppIdentity] {
        // 路径短的（父 bundle）在前，保证父 App 先被收录
        let sorted = apps.sorted {
            ($0.bundlePath ?? "").count < ($1.bundlePath ?? "").count
        }
        var result: [AppIdentity] = []
        var bundlePaths: [String] = []

        for app in sorted {
            guard let path = app.bundlePath else {
                result.append(app)
                continue
            }
            let nested = bundlePaths.contains { path.hasPrefix($0 + "/") }
            if nested { continue }
            bundlePaths.append(path)
            result.append(app)
        }
        return result
    }
}
