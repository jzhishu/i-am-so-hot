import XCTest
@testable import ThermalCore

final class AppRegistryMergerTests: XCTestCase {

    private func app(_ id: String, path: String?) -> AppIdentity {
        AppIdentity(id: id, rootPid: 1, bundleID: id, localizedName: id, bundlePath: path)
    }

    // MARK: - Electron Helper 归并（截图发现的 P0 问题）

    func testNestedHelperAppIsMergedIntoParent() {
        let apps = [
            app("com.todesktop.cursor.helper", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app"),
            app("com.todesktop.cursor", path: "/Applications/Cursor.app"),
        ]
        let merged = AppRegistryMerger.merge(apps)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "com.todesktop.cursor")
    }

    func testUnrelatedAppsAreBothKept() {
        let apps = [
            app("com.google.Chrome", path: "/Applications/Google Chrome.app"),
            app("com.todesktop.cursor", path: "/Applications/Cursor.app"),
        ]
        XCTAssertEqual(AppRegistryMerger.merge(apps).count, 2)
    }

    func testAppWithoutBundlePathIsKept() {
        let apps = [
            app("com.example.noapp", path: nil),
            app("com.todesktop.cursor", path: "/Applications/Cursor.app"),
        ]
        XCTAssertEqual(AppRegistryMerger.merge(apps).count, 2)
    }

    /// 嵌套关系判断不受注册顺序影响（helper 先出现也能正确归并）
    func testMergeIsOrderIndependent() {
        let helperFirst = [
            app("com.todesktop.cursor.helper", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app"),
            app("com.todesktop.cursor", path: "/Applications/Cursor.app"),
        ]
        let merged = AppRegistryMerger.merge(helperFirst)
        XCTAssertEqual(merged.map(\.id), ["com.todesktop.cursor"])
    }
}

extension BaselineTrackerTests {

    // MARK: - 冷启动校准（截图发现的 P0 问题：baseline 高于实测温度导致 +°C 恒为 0）

    func testFirstReadingInitializesBaselineDirectly() {
        var tracker = BaselineTracker(initial: 45)
        // 即使非 idle，首个有效温度也应直接成为 baseline
        tracker.update(currentCelsius: 43.7, isIdle: false)
        XCTAssertEqual(tracker.baseline, 43.7, accuracy: 1e-9)
        XCTAssertTrue(tracker.isInitialized)
    }

    func testAfterInitializationLearnsOnlyWhenIdle() {
        var tracker = BaselineTracker(initial: 45, alpha: 0.5)
        tracker.update(currentCelsius: 44, isIdle: false) // 初始化
        tracker.update(currentCelsius: 80, isIdle: false) // 高负载：不学习
        XCTAssertEqual(tracker.baseline, 44, accuracy: 1e-9)
        tracker.update(currentCelsius: 46, isIdle: true)  // idle：EMA 学习
        XCTAssertEqual(tracker.baseline, 45, accuracy: 1e-9)
    }
}
