// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThermalCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ThermalCore", targets: ["ThermalCore"])
    ],
    targets: [
        .target(name: "ThermalCore"),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore"]),
    ]
)
