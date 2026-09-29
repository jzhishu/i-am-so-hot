import AppKit

/// I AM SO HOT — 菜单栏常驻工具入口。
///
/// 菜单栏 App：LSUIElement = YES（无 Dock 图标），
/// 启动后由 MenuBarController 管理 NSStatusItem + NSPopover 生命周期。
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }
}
