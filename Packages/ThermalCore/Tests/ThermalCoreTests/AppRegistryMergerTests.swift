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
