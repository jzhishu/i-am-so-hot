import Foundation
import ThermalCore

// 直接探测 resolver 对 Docker 相关进程的归属结果
let resolver = AppResolver()
// 模拟注册表（NSRunningApplication 层）
let registry = NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker")

let pids: [pid_t] = [96148, 95885, 39655, 39674, 88232]
for pid in pids {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let len = proc_pidpath(pid, &buf, UInt32(MAXPATHLEN))
    let path = len > 0 ? String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    let sample = ProcessSample(
        pid: pid, parentPid: 0, executablePath: path,
        processName: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid\(pid)",
        cpuTimeDelta: 0
    )
    let ownership = resolver.resolve(sample, allSamples: [:])
    print("pid \(pid) [\(path ?? "?")] -> appID=\(ownership.appID) method=\(ownership.method) conf=\(ownership.confidence)")
}
