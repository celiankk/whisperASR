// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperASR",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "CWhisper",
            path: "Frameworks/CWhisper.xcframework"
        ),
        .executableTarget(
            name: "WhisperASR",
            dependencies: ["CWhisper"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        )
    ]
)
