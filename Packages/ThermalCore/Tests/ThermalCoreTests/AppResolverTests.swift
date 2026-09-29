import XCTest
@testable import ThermalCore

final class AppResolverTests: XCTestCase {

    private let chrome = AppIdentity(
        id: "com.google.Chrome",
        rootPid: 1000,
        bundleID: "com.google.Chrome",
        localizedName: "Google Chrome",
        bundlePath: "/Applications/Google Chrome.app",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    )
    private let cursor = AppIdentity(
        id: "com.todesktop.230313mzl4w4u92",
        rootPid: 2000,
        bundleID: "com.todesktop.230313mzl4w4u92",
        localizedName: "Cursor",
        bundlePath: "/Applications/Cursor.app",
        executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor"
    )

    private func makeResolver() -> AppResolver {
        let resolver = AppResolver()
        resolver.updateRegistry([chrome, cursor])
        return resolver
    }

    private func sample(
        _ pid: pid_t, ppid: pid_t = 1,
        name: String = "proc", path: String? = nil
    ) -> ProcessSample {
        ProcessSample(pid: pid, parentPid: ppid, executablePath: path, processName: name, cpuTimeDelta: 0)
    }

    // MARK: - 优先级 1：PID 直接命中

    func testDirectPIDMatch() {
        let resolver = makeResolver()
        let s = sample(1000, name: "Google Chrome")
        let result = resolver.resolve(s, allSamples: [1000: s])
        XCTAssertEqual(result.appID, chrome.id)
        XCTAssertEqual(result.method, .runningApplication)
        XCTAssertEqual(result.confidence, 1.0)
    }

    // MARK: - 优先级 2：Bundle path 匹配（Chrome Helper 归并的核心用例）

    func testHelperInsideBundleMatchesApp() {
        let resolver = makeResolver()
        let helper = sample(
            1001, ppid: 1000,
            name: "Google Chrome Helper (Renderer)",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1.0/Helpers/Google Chrome Helper (Renderer)"
        )
        let result = resolver.resolve(helper, allSamples: [1001: helper])
        XCTAssertEqual(result.appID, chrome.id)
        XCTAssertEqual(result.method, .sameBundle)
    }

    // MARK: - 优先级 3：PPID 向上追溯（bundle 外的独立 helper）

    func testAncestorMatchForProcessOutsideBundle() {
        let resolver = makeResolver()
        let xpc = sample(3001, ppid: 1000, name: "Some XPC Service", path: "/Library/PrivilegedHelperTools/xpc-helper")
        let result = resolver.resolve(xpc, allSamples: [1000: sample(1000), 3001: xpc])
        XCTAssertEqual(result.appID, chrome.id)
        XCTAssertEqual(result.method, .ancestor)
    }

    // MARK: - 系统进程规则

    func testKernelTaskGoesToMacOS() {
        let resolver = makeResolver()
        let kernel = sample(0, ppid: 0, name: "kernel_task", path: nil)
        let result = resolver.resolve(kernel, allSamples: [0: kernel])
        XCTAssertEqual(result.appID, AppIdentity.macOS.id)
        XCTAssertEqual(result.method, .systemRule)
    }

    func testSystemDaemonGoesToMacOS() {
        let resolver = makeResolver()
        let daemon = sample(500, name: "WindowServer", path: "/System/Library/.../WindowServer")
        let result = resolver.resolve(daemon, allSamples: [500: daemon])
        XCTAssertEqual(result.appID, AppIdentity.macOS.id)
        XCTAssertEqual(result.method, .systemRule)
    }

    // MARK: - 兜底

    func testUnknownGoesToOther() {
        let resolver = makeResolver()
        let unknown = sample(4000, name: "my-script", path: "/Users/someone/bin/my-script")
        let result = resolver.resolve(unknown, allSamples: [4000: unknown])
        XCTAssertEqual(result.appID, AppIdentity.other.id)
        XCTAssertEqual(result.method, .unknown)
    }

    // MARK: - 缓存（技术方案 §4.5）

    func testCacheReturnsSameResultAndSurvivesUntilInvalidated() {
        let resolver = makeResolver()
        let helper = sample(
            1001, ppid: 1,
            name: "Google Chrome Helper",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper"
        )
        let first = resolver.resolve(helper, allSamples: [1001: helper])
        XCTAssertEqual(first.method, .sameBundle)

        // 注册表移除 Chrome 后：未 invalidate 时仍命中缓存
        resolver.updateRegistry([cursor])
        let cached = resolver.resolve(helper, allSamples: [1001: helper])
        XCTAssertEqual(cached.appID, chrome.id)

        // invalidate 后重新解析
        resolver.invalidateCache()
        let fresh = resolver.resolve(helper, allSamples: [1001: helper])
        XCTAssertEqual(fresh.appID, AppIdentity.other.id)
    }
}
