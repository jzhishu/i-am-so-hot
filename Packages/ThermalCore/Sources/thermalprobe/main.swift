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
log("== done ==")
