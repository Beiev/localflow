// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LocalFlowCore", targets: ["LocalFlowCore"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "5c19d5e12320e22bbfb7a1877b089d2665a69add"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        // mlx-swift-lm 3.x loads tokenizers through client-provided swift-transformers.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.9")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LocalFlowCore", dependencies: ["CSQLite", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "MLXHuggingFace", package: "mlx-swift-lm"), .product(name: "Tokenizers", package: "swift-transformers")], resources: [.process("Resources")]),
        .testTarget(name: "LocalFlowCoreTests", dependencies: ["LocalFlowCore"])
    ], swiftLanguageModes: [.v5]
)
