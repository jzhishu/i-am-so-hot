import AppKit

/// I AM SO HOT — 菜单栏常驻工具入口。
///
/// 菜单栏 App：LSUIElement = YES（无 Dock 图标）。
/// 启动后：MonitorService 驱动自适应采样循环，MenuBarController 管理
/// NSStatusItem + NSPopover 生命周期。
///
/// 注意：使用显式 main.swift 而不是 @main/@NSApplicationMain——
/// 实测（Swift 6.3 / macOS 26）@main 在直接执行二进制时
/// applicationDidFinishLaunching 不触发，显式入口无此问题。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var service: MonitorService?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = MonitorService()
        self.service = service
        menuBarController = MenuBarController(service: service)
        service.start()
    }
}

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
