import Foundation
import IOKit

/// 前置摄像头采集状态检测（IOKit 公开属性，无私有 API）。
///
/// 实测（2026-10-13，M2 Pro）：摄像头开启时
/// `AppleH13CamIn.FrontCameraStreaming = 1`，关闭归零。
/// 成本：单次类匹配 + 属性读取，亚毫秒级。
///
/// 已知限制：驱动类名随芯片代次变化（H13 = M2 代），未验证的机型
/// 匹配不到条目时一律返回 false（优雅降级，不影响主流程）。
/// 摄像头客户端走 CMIO 扩展，IORegistry 看不到「谁在用」（只有
/// appleh13camerad 守护进程），因此只提供开关状态、不做归属。
public struct CameraStateSampler: Sendable {

    /// 各代芯片的 ISP 驱动类名候选（仅 M2 代真机验证过）
    private static let ispClassNames = ["AppleH13CamIn", "AppleH16CamIn", "AppleH15CamIn", "AppleH10CamIn"]

    public init() {}

    /// 前置摄像头是否正在采集（无法确定时返回 false）
    public func isFrontCameraStreaming() -> Bool {
        for className in Self.ispClassNames {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(className), &iter
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }
            while case let entry = IOIteratorNext(iter), entry != 0 {
                defer { IOObjectRelease(entry) }
                let value = IORegistryEntryCreateCFProperty(
                    entry, "FrontCameraStreaming" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue()
                if let streaming = value as? Bool, streaming { return true }
                if let streaming = value as? Int, streaming != 0 { return true }
            }
        }
        return false
    }
}
