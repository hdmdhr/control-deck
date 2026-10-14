// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ControlDeck",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "control-deck", targets: ["ControlDeck"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        )
    ],
    targets: [
        .systemLibrary(
            name: "COpus",
            path: "Sources/COpus",
            pkgConfig: "opus",
            providers: [
                .brew(["opus"])
            ]
        ),
        .executableTarget(
            name: "ControlDeck",
            dependencies: [
                "COpus",
                .product(
                    name: "FluidAudio",
                    package: "FluidAudio"
                ),
                .product(
                    name: "WhisperKit",
                    package: "argmax-oss-swift"
                )
            ],
            path: "Sources/ControlDeck",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "LocalSpeechSmokeTest",
            dependencies: [
                .product(
                    name: "FluidAudio",
                    package: "FluidAudio"
                ),
                .product(
                    name: "WhisperKit",
                    package: "argmax-oss-swift"
                )
            ],
            path: "Tools/LocalSpeechSmokeTest"
        )
    ],
    swiftLanguageModes: [.v5]
)
