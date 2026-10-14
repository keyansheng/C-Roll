// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GateCore",
    products: [.library(name: "GateCore", targets: ["GateCore"])],
    targets: [
        .target(name: "GateCore", path: "Gate/Core"),
        .testTarget(name: "GateCoreTests", dependencies: ["GateCore"], path: "Tests/GateCoreTests")
    ]
)
