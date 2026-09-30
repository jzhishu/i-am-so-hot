import Foundation

/// 系统 UI 组件规则（PRD §8.3：关键系统组件不提供 Quit）。
///
/// 注意与系统进程规则的区别：Safari 等 Apple 普通 App 是用户可以正常退出的，
/// 只有系统 UI 组件（控制中心 / Dock / Finder 等）需要保护——
/// 对它们 Quit 可能导致系统 UI 异常。
public enum SystemComponentRules {

    /// macOS 系统 UI 组件 bundleID 清单
    public static let systemUIComponentBundleIDs: Set<String> = [
        "com.apple.controlcenter",        // 控制中心
        "com.apple.dock",                 // Dock
        "com.apple.finder",               // 访达
        "com.apple.notificationcenterui", // 通知中心
        "com.apple.systemuiserver",       // 系统 UI 服务
        "com.apple.Spotlight",            // 聚焦
        "com.apple.wallpaper.agent",      // 墙纸
        "com.apple.ScreenTimeAgent",      // 屏幕使用时间
        "com.apple.AirDropUIAgent",       // 隔空投送 UI
        "com.apple.VolumeControl",        // 音量控制
    ]

    public static func isSystemUIComponent(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return systemUIComponentBundleIDs.contains(bundleID)
    }
}
