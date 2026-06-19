// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperASR",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Lightweight, pure-Swift HTTP server (no transitive deps) used to expose
        // the local OpenAI-compatible transcription API.
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
    ],
    targets: [
        .binaryTarget(
            name: "CWhisper",
            path: "Frameworks/CWhisper.xcframework"
        ),
        .executableTarget(
            name: "WhisperASR",
            dependencies: [
                "CWhisper",
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
