// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperASR",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Lightweight, pure-Swift HTTP server (no transitive deps) used to expose
        // the local OpenAI-compatible transcription API.
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
        // Core ML / ANE runtime for NVIDIA Nemotron streaming ASR models.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .binaryTarget(
            name: "CWhisper",
            path: "Frameworks/CWhisper.xcframework"
        ),
        .binaryTarget(
            name: "CTranscribe",
            path: "Frameworks/CTranscribe.xcframework"
        ),
        // sherpa-onnx v1.13.6 no-tts 精简静态库（自包含 onnxruntime）：
        // Swift → C API（c-api.h）→ ONNX Runtime；FunASR 推理后端。
        .binaryTarget(
            name: "SherpaONNX",
            path: "Frameworks/SherpaONNX.xcframework"
        ),
        // C11 原子操作 shim（仅头文件，static inline）：SPSC 环形缓冲的
        // 64 位游标 acquire/release 内存顺序（Swift 不暴露 _Atomic 类型）。
        .target(
            name: "CRealtimeAtomics",
            path: "SourcesC/CRealtimeAtomics",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "WhisperASR",
            dependencies: [
                "CWhisper",
                "CTranscribe",
                "SherpaONNX",
                "CRealtimeAtomics",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ],
            path: "Sources",
            resources: [
                // MSL 着色器源码（SPM 不编译 .metal → 运行时
                // device.makeLibrary(source:) 一次性编译缓存）。
                .copy("Pipeline/Subtitle/FloatingLetter/Metal"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        // 纯逻辑单元测试（字幕断句/累积/去重/分割等，见 HANDOFF 坑 13——
        // 此前项目没有任何测试；2026-08-22 会话补齐核心逻辑的回归保护）。
        .testTarget(
            name: "WhisperASRTests",
            dependencies: ["WhisperASR"],
            path: "Tests/WhisperASRTests"
        )
    ]
)
