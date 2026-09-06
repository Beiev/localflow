// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LocalFlowCore", targets: ["LocalFlowCore"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "5c19d5e12320e22bbfb7a1877b089d2665a69add"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.29.3")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LocalFlowCore", dependencies: ["CSQLite", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm")], resources: [.process("Resources")]),
        .testTarget(name: "LocalFlowCoreTests", dependencies: ["LocalFlowCore"])
    ], swiftLanguageModes: [.v5]
)
