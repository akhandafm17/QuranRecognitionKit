// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuranRecognitionKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "QuranRecognitionKit",
            targets: ["QuranRecognitionKit"]
        ),
        .executable(
            name: "QuranRecognitionManualHarness",
            targets: ["QuranRecognitionManualHarness"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            from: "1.24.0"
        )
    ],
    targets: [
        .target(
            name: "QuranRecognitionKit",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            resources: [
                .copy("Resources/FastConformerQuranCTC.onnx.zip"),
                .process("Resources/vocab.json"),
                .process("Resources/quran.json")
            ]
        ),
        .executableTarget(
            name: "QuranRecognitionManualHarness",
            dependencies: ["QuranRecognitionKit"]
        ),
        .testTarget(
            name: "QuranRecognitionKitTests",
            dependencies: ["QuranRecognitionKit"],
            resources: [
                .process("Resources/baqarah_recitation_windows.json"),
                .process("Resources/recording_chain_112_114.json"),
                .process("Resources/recording_alala_87.json"),
                .process("Resources/recording_kahf_18.json")
            ]
        )
    ]
)
