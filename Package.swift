// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hinomi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hinomi", targets: ["hinomi"]),
        .executable(name: "hinomi-hook", targets: ["hinomi-hook"]),
        .library(name: "HinomiCore", targets: ["HinomiCore"]),
    ],
    targets: [
        // Foundation のみに依存する純粋なコア（AppKit/SwiftUI を持ち込まない）。
        // hinomi-hook を軽く保つため、UI は hinomi ターゲット側に置く。
        .target(name: "HinomiCore"),
        .executableTarget(name: "hinomi", dependencies: ["HinomiCore"]),
        .executableTarget(name: "hinomi-hook", dependencies: ["HinomiCore"]),
        .testTarget(name: "HinomiCoreTests", dependencies: ["HinomiCore"]),
    ]
)
