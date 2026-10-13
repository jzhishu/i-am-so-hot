import CoreAudio
import Foundation

/// 麦克风/音频输入采集者枚举（macOS 14.4+ 公开 API）。
///
/// CoreAudio 为每个连接音频系统的进程维护一个 process object，
/// `kAudioProcessPropertyIsRunningInput` 标记其是否正在采集输入（麦克风）。
/// 成本：两次 AudioObjectGetPropertyData，微秒级，每 tick 调用无压力。
///
/// 用途（能耗对账的归因增强）：语音/视频通话时摄像头 ISP、编解码引擎、
/// 音频 DSP 的热量不占进程 CPU 时间，若发现某 App 正在采集麦克风，
/// 硬件缺口优先归给它而不是笼统的 System Hardware 桶。
public struct AudioInputSampler: Sendable {

    /// API 不可用（旧系统 / 查询失败）时置 false，上层降级跳过
    public private(set) var isAvailable = true

    public init() {}

    /// 当前正在采集音频输入的进程 PID 集合
    public mutating func activeInputPIDs() -> Set<pid_t> {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr, size > 0 else {
            isAvailable = false
            return []
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &objects) == noErr else {
            isAvailable = false
            return []
        }

        var result: Set<pid_t> = []
        for obj in objects {
            var pid: pid_t = 0
            var running: UInt32 = 0
            if Self.readProperty(obj, selector: kAudioProcessPropertyPID, into: &pid),
               Self.readProperty(obj, selector: kAudioProcessPropertyIsRunningInput, into: &running),
               running != 0 {
                result.insert(pid)
            }
        }
        return result
    }

    private static func readProperty<T>(
        _ obj: AudioObjectID, selector: AudioObjectPropertySelector, into value: inout T
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
    }
}
