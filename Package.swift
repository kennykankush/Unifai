// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unifai",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Unifai", targets: ["Unifai"]),
        .executable(name: "unifai-mcp", targets: ["UnifaiMCP"])
    ],
    targets: [
        .target(name: "UnifaiCore"),
        .executableTarget(name: "Unifai", dependencies: ["UnifaiCore"], resources: [.copy("Resources/Logos")]),
        .executableTarget(name: "UnifaiMCP", dependencies: ["UnifaiCore"]),
        .testTarget(name: "UnifaiCoreTests", dependencies: ["UnifaiCore"])
    ],
    swiftLanguageModes: [.v5]
)
