import AppKit
import SwiftUI
import ThermalCore

/// 菜单栏控制器：管理 NSStatusItem（只显示温度数字）与 NSPopover。
///
/// 产品原则（PRD §5）：
/// - 菜单栏只显示一个温度数字，无图标动画、无状态标签。
/// - 仅在温度值实际变化时更新 title。
@MainActor
final class MenuBarController: NSObject {

    private let service: MonitorService
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<PopoverView>
    /// popover 最近一次关闭时间：用于修复 .transient 的经典缺陷——
    /// 点击菜单栏图标想关闭面板时，系统先把面板当“外部点击”关闭，
    /// 随后按钮 action 又触发 toggle 将其重新打开（体感：点图标关不掉）。
    private var lastPopoverCloseTime: Date?

    init(service: MonitorService) {
        self.service = service
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        hostingController = NSHostingController(rootView: PopoverView(
            snapshot: MonitorSnapshot(
                temperatureCelsius: nil, baselineCelsius: 45, totalCPU: 0,
                thermalStateElevated: false, mode: .sleep, apps: [],
                appsTotalDeltaC: 0, estimatedCelsius: nil, residualBaselineCelsius: nil
            ),
            iconProvider: { _ in nil },
            onQuit: { _ in }
        ))
        super.init()

        popover.behavior = .transient
        popover.animates = false // 克制原则：无动画（PRD §4.2）
        popover.delegate = self
        popover.contentViewController = hostingController
        // 让 SwiftUI 内容决定 popover 尺寸，避免首次弹出时位置/尺寸跳动
        hostingController.sizingOptions = .preferredContentSize

        if let button = statusItem.button {
            button.title = "--°"
            button.target = self
            button.action = #selector(togglePopover)
        }

        service.onSnapshot = { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    // MARK: - 快照驱动 UI（UI 只消费快照，技术方案 §19）

    private func handle(_ snapshot: MonitorSnapshot) {
        updateTemperature(snapshot.temperatureCelsius)
        if popover.isShown {
            hostingController.rootView = PopoverView(
                snapshot: snapshot,
                iconProvider: { [weak self] in self?.service.icon(for: $0) },
                onQuit: { [weak self] in self?.service.quit($0) }
            )
        }
    }

    /// 更新菜单栏温度显示。仅当值变化时刷新，避免不必要的 UI 绘制。
    private func updateTemperature(_ celsius: Double?) {
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

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 本次点击已把面板关掉了（点击图标对 .transient 面板而言是“外部点击”），
        // 不要再重新打开
        if let lastClose = lastPopoverCloseTime,
           Date().timeIntervalSince(lastClose) < 0.3 {
            return
        }
        if let snapshot = service.snapshot {
            hostingController.rootView = PopoverView(
                snapshot: snapshot,
                iconProvider: { [weak self] in self?.service.icon(for: $0) },
                onQuit: { [weak self] in self?.service.quit($0) }
            )
        }
        // 打开面板 → 进入 LIVE 采样（PRD §10）
        service.setPanelOpen(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

@MainActor
extension MenuBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseTime = Date()
        // 关闭面板 → 采样自动降级（PRD §10）
        service.setPanelOpen(false)
    }
}
