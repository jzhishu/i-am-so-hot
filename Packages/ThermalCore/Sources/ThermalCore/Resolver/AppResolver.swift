import Foundation

/// 进程 → App 归属解析器（技术方案 §4）。
///
/// 纯逻辑实现，不依赖 AppKit：App 注册表由调用方（App 层）注入。
/// 匹配优先级（§4.3）：
/// 1. PID 直接命中注册表（NSRunningApplication）
/// 2. executable path 位于某 .app Bundle 内
/// 3. 沿 PPID 向上追溯
/// 4. responsible PID / coalition —— v0.2 增强（Roadmap）
/// 5. 系统进程规则 → macOS
/// 6. 兜底 → Other
///
/// 缓存（§4.5）：PID → ownership 结果缓存；注册表变化时由调用方 invalidate。
public final class AppResolver {

    /// 系统进程可执行路径前缀：命中即归类为 macOS，不提供 Quit（PRD §8.3）。
    private static let systemPathPrefixes = [
        "/System/Library/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/usr/lib/",
        "/sbin/",
        "/Library/Apple/",
    ]

    private var appsByPid: [pid_t: AppIdentity] = [:]
    /// bundlePath（如 /Applications/Google Chrome.app）→ App
    private var appsByBundlePath: [String: AppIdentity] = [:]
    private var cache: [pid_t: ProcessOwnership] = [:]

    public init() {}

    /// 注入当前运行 App 注册表（App 层由 NSWorkspace 构建）。
    public func updateRegistry(_ apps: [AppIdentity]) {
        appsByPid = Dictionary(
            apps.compactMap { app in app.rootPid.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        appsByBundlePath = Dictionary(
            apps.compactMap { app in app.bundlePath.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 注册表变化（App 启动/退出）后调用，清空归属缓存（§4.5）。
    /// TODO(v0.2): PID reuse 检测，替代全量清空。
    public func invalidateCache() {
        cache.removeAll()
    }

    public func resolve(_ sample: ProcessSample, allSamples: [pid_t: ProcessSample]) -> ProcessOwnership {
        if let cached = cache[sample.pid] { return cached }
        let ownership = resolveUncached(sample, allSamples: allSamples)
        cache[sample.pid] = ownership
        return ownership
    }

    private func resolveUncached(
        _ sample: ProcessSample,
        allSamples: [pid_t: ProcessSample]
    ) -> ProcessOwnership {
        // 0. kernel_task / launchd
        if sample.pid <= 1 {
            return ProcessOwnership(appID: AppIdentity.macOS.id, confidence: 1.0, method: .systemRule)
        }
        // 1. PID 直接命中
        if let app = appsByPid[sample.pid] {
            return ProcessOwnership(appID: app.id, confidence: 1.0, method: .runningApplication)
        }
        // 2. Bundle path 匹配（覆盖 Chrome Helper / Renderer 等 bundle 内进程）
        if let path = sample.executablePath, let app = app(containingPath: path) {
            return ProcessOwnership(appID: app.id, confidence: 0.98, method: .sameBundle)
        }
        // 3. PPID 向上追溯（覆盖 XPC / 独立 helper 进程）
        var current = sample
        var visited: Set<pid_t> = [sample.pid]
        while current.parentPid > 1, !visited.contains(current.parentPid) {
            guard let parent = allSamples[current.parentPid] else { break }
            visited.insert(parent.pid)
            if let app = appsByPid[parent.pid] {
                return ProcessOwnership(appID: app.id, confidence: 0.95, method: .ancestor)
            }
            if let path = parent.executablePath, let app = app(containingPath: path) {
                return ProcessOwnership(appID: app.id, confidence: 0.90, method: .ancestor)
            }
            current = parent
        }
        // 4. 系统进程规则
        if isSystemProcess(sample) {
            return ProcessOwnership(appID: AppIdentity.macOS.id, confidence: 1.0, method: .systemRule)
        }
        // 5. 兜底
        return ProcessOwnership(appID: AppIdentity.other.id, confidence: 0.5, method: .unknown)
    }

    /// executable path 是否位于某已注册 App 的 .app bundle 内
    /// （取最长前缀匹配，避免嵌套 bundle 误判）。
    private func app(containingPath path: String) -> AppIdentity? {
        var best: (length: Int, app: AppIdentity)?
        for (bundlePath, app) in appsByBundlePath {
            if path == bundlePath || path.hasPrefix(bundlePath + "/") {
                if best == nil || bundlePath.count > best!.length {
                    best = (bundlePath.count, app)
                }
            }
        }
        return best?.app
    }

    private func isSystemProcess(_ sample: ProcessSample) -> Bool {
        guard let path = sample.executablePath else {
            // 无可执行路径的系统进程（如 kernel_task）
            return true
        }
        return Self.systemPathPrefixes.contains { path.hasPrefix($0) }
    }
}
