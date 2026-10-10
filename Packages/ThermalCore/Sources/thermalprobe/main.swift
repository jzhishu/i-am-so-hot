import Foundation
import ThermalCore

/// thermalprobe — Phase 1 真机验证工具。
///
/// 用法：swift run --package-path Packages/ThermalCore thermalprobe
/// 输出：温度（IOHID）/ Total CPU / Top 5 CPU 进程，验证采集链路可用。

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

log("== I AM SO HOT · thermalprobe ==")

// 1. 温度
log("[1] IOHID temperature ...")
let provider = IOHIDTemperatureProvider()
let reading = provider.read()
if let temp = reading.dieCelsius {
    log(String(format: "Temperature (die): %.1f°C", temp))
} else {
    log("Temperature: unavailable (nil)")
}
if let slow = reading.slowAnchorCelsius {
    log(String(format: "Slow anchor (baseline 物理锚点): %.1f°C", slow))
} else {
    log("Slow anchor: unavailable")
}

// 1.5 传感器清点（模型设计验证）
log("[1.5] sensor inventory ...")
for sensor in SensorInventory.all() {
    log(String(format: "  %@: %.1f°C", sensor.name, sensor.celsius))
}

// 2. Total CPU（两次采样差分）
log("[2] total CPU ...")
let sampler = CPUSampler()
_ = sampler.totalCPU()
Thread.sleep(forTimeInterval: 1)
if let cpu = sampler.totalCPU() {
    log(String(format: "Total CPU: %.1f%%", cpu * 100))
} else {
    log("Total CPU: unavailable")
}

// 3. Per-process CPU Top 5（两次采样差分）
log("[3] process CPU ...")
let collector = ProcessCollector()
_ = collector.collectSample()
Thread.sleep(forTimeInterval: 1)
let samples = collector.collectSample()
let top = samples.sorted { $0.cpuTimeDelta > $1.cpuTimeDelta }.prefix(5)
log("Top 5 processes by CPU (last 1s):")
for s in top {
    log("  \(s.processName) (pid \(s.pid)) cpu=\(String(format: "%.2f", s.cpuTimeDelta))s")
}
log("Total processes: \(samples.count)")

// 3.5 EPERM 最小 sample 验证（v0.5 review 修复）：WindowServer（_windowserver
// 用户）proc_pidinfo 无权限，应从「静默丢弃」变为「路径归属 macOS」
if let ws = samples.first(where: { $0.executablePath?.contains("WindowServer") == true }) {
    log("WindowServer (pid \(ws.pid)) in samples: name=\(ws.processName) ppid=\(ws.parentPid)")
} else {
    log("WindowServer NOT in samples（回归！EPERM 进程被丢弃）")
}

// 4. Per-process GPU Top 5（v0.5：AGXDeviceUserClient.accumulatedGPUTime 差分）
log("[4] process GPU ...")
let gpuSampler = GPUSampler()
let gpuBase = gpuSampler.cumulativeGPUTimes() ?? [:]
Thread.sleep(forTimeInterval: 1)
let gpuDeltas = GPUSampler.deltas(current: gpuSampler.cumulativeGPUTimes() ?? [:], previous: gpuBase)
let gpuTop = gpuDeltas.sorted { $0.value > $1.value }.prefix(5)
if gpuSampler.isAvailable {
    log("Top 5 processes by GPU (last 1s):")
    for (pid, delta) in gpuTop {
        let name = samples.first { $0.pid == pid }?.processName ?? "?"
        log("  \(name) (pid \(pid)) gpu=\(String(format: "%.2f", delta))s")
    }
    log("GPU clients with delta: \(gpuDeltas.count)")
} else {
    log("GPU sampling unavailable (enumeration failed)")
}

// 5. 设备级功耗（v0.5：IOReport Energy Model，用于 w_g 标定）
log("[5] device power ...")
if let meter = DevicePowerMeter() {
    let r1 = meter.readPower()
    log("  first read: \(r1 == nil ? "nil（建立基准，预期）" : "NON-NIL（异常！\(r1!)）")")
    Thread.sleep(forTimeInterval: 2)
    if let r2 = meter.readPower() {
        log(String(format: "  CPU: %.2f W, GPU: %.2f W", r2.cpuWatts, r2.gpuWatts))
    } else {
        log("  second read: nil（异常）")
    }
} else {
    log("  DevicePowerMeter unavailable")
}
log("== done ==")

// 6. ThermalMonitor 集成验证（复现 App 首 tick 行为）
log("[6] ThermalMonitor tick ...")
let monitor = ThermalMonitor()
let snap1 = monitor.tick()
log("  tick1: power=\(String(describing: monitor.lastPowerReading)) gpuWeight=\(String(format: "%.2f", monitor.gpuWeight)) temp=\(snap1.temperatureCelsius ?? -1))")
Thread.sleep(forTimeInterval: 2)
_ = monitor.tick()
log("  tick2: power=\(String(describing: monitor.lastPowerReading))")
