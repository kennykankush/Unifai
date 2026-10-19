// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unifai",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Unifai", targets: ["Unifai"]),
        .executable(name: "unifai-mcp", targets: ["UnifaiMCP"]),
        .executable(name: "UnifaiWidget", targets: ["UnifaiWidget"])
    ],
    targets: [
        .target(name: "UnifaiCore"),
        .target(name: "UnifaiWidgetUI", dependencies: ["UnifaiCore"]),
        // Provider logos are copied into Contents/Resources/Logos by scripts/assemble-app.sh.
        .executableTarget(name: "Unifai", dependencies: ["UnifaiCore", "UnifaiWidgetUI"], exclude: ["Resources"]),
        // Desktop widgets; scripts/assemble-app.sh wraps this binary into Contents/PlugIns/UnifaiWidget.appex.
        .executableTarget(name: "UnifaiWidget", dependencies: ["UnifaiCore", "UnifaiWidgetUI"]),
        .executableTarget(name: "UnifaiMCP", dependencies: ["UnifaiCore"]),
        .testTarget(name: "UnifaiCoreTests", dependencies: ["UnifaiCore"])
    ],
    swiftLanguageModes: [.v5]
)
