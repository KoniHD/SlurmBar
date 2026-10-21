// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlurmBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SlurmBar", targets: ["SlurmBar"])],
    targets: [
        .target(name: "SlurmBarCore"),
        .executableTarget(name: "SlurmBar", dependencies: ["SlurmBarCore"]),
        .testTarget(name: "SlurmBarCoreTests", dependencies: ["SlurmBarCore"]),
        .testTarget(name: "SlurmBarTests", dependencies: ["SlurmBar", "SlurmBarCore"])
    ]
)
