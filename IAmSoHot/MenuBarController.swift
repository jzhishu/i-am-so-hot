import AppKit
import SwiftUI

/// 菜单栏控制器：管理 NSStatusItem（只显示温度数字）与 NSPopover。
///
/// 产品原则（PRD §5）：
/// - 菜单栏只显示一个温度数字，无图标动画、无状态标签。
/// - 仅在温度值实际变化时更新 title。
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let popover: NSPopover

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView())

        if let button = statusItem.button {
            // TODO(Phase 1): 接入 TemperatureProvider 真实温度，当前为占位
            button.title = "--°"
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    /// 更新菜单栏温度显示。仅当值变化时刷新，避免不必要的 UI 绘制。
    func updateTemperature(_ celsius: Double?) {
        let title: String
        if let celsius {
            title = "\(Int(celsius.rounded()))°"
        } else {
            title = "--°"
        }
        if statusItem.button?.title != title {
            statusItem.button?.title = title
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // TODO(Phase 5): 打开面板时切换采样模式 SLEEP/WATCH -> LIVE，
            // 关闭后降级。由 ThermalCore.Scheduler 负责。
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
