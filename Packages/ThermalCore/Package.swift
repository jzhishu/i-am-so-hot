// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThermalCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ThermalCore", targets: ["ThermalCore"]),
        .executable(name: "thermalprobe", targets: ["thermalprobe"]),
    ],
    targets: [
        // IOHID 私有 API 的 C shim，隔离私有符号（温度读取风险隔离，见 TechStack §4.1）
        .target(
            name: "CHIDBridge",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "ThermalCore",
            dependencies: ["CHIDBridge"]
        ),
        // 手动验证工具：打印温度 / Total CPU / Top 进程，用于 Phase 1 真机验证
        .executableTarget(
            name: "thermalprobe",
            dependencies: ["ThermalCore"]
        ),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore"]),
    ]
)
