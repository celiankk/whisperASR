# 声记 SonicScribe

> 内部标识（Swift Package 模块名、Application Support 目录、日志目录）仍为
> `WhisperASR`——改名只动对外的品牌与 bundle 标识，不动数据目录，
> 以免用户既有历史记录与模型需要迁移。

<p align="center">
  <img src="Assets/icon_1024.png" width="128" height="128" alt="SonicScribe Icon" />
</p>

<p align="center">
  <strong>High-performance, versatile offline & online speech transcription, live subtitles, and bilingual translation workbench designed exclusively for macOS.</strong>
</p>

<p align="center">
  English | <a href="README.zh-cn.md">简体中文</a>
</p>

---

## 🌟 Highlights

SonicScribe (声记) is a native macOS speech transcription and live subtitle workstation powered by **hardware-accelerated on-device inference (Metal GPU + Apple Neural Engine)** and **online LLMs**. It provides a seamless end-to-end workflow from internal application audio recording, live floating subtitle overlays, multi-engine streaming recognition, and real-time translation to structured AI meeting minutes.

```
[ App Audio / Mic Input ] ──► [ Silero Neural VAD + Adaptive Cuts ] ──► [ Multi-Engine ASR Dispatch ]
                                                                                  │
┌─────────────────────────────── Real-Time Pipeline ──────────────────────────────┴────────────────┐
│                                                                                                  │
│   ┌───────────────────────────┐         ┌───────────────────────────┐                            │
│   │  Unified Floating Overlay │         │  LLM / Native Translation │                            │
│   │  (Drag / Resize / Pin)    │ ◄───────┤  (Streaming SSE + AutoFix)│                            │
│   └─────────────┬─────────────┘         └─────────────▲─────────────┘                            │
│                 │                                     │                                          │
│                 ▼                                     │                                          │
│   ┌───────────────────────────┐         ┌─────────────┴─────────────┐                            │
│   │ OBS / Cleanfeed Stream Win│         │ OpenAI-Compatible API Srv │                            │
│   └───────────────────────────┘         └───────────────────────────┘                            │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📸 Screenshots

| Live transcription with bilingual subtitles | Bilingual transcript |
|---|---|
| ![Live recording](docs/screenshots/live_recording.png) | ![Bilingual transcript](docs/screenshots/transcript.png) |

| Interactive transcript with synced playback | AI meeting minutes |
|---|---|
| ![Transcript and playback](docs/screenshots/live.png) | ![Meeting minutes](docs/screenshots/minutes.png) |

| Speech recognition models | Settings |
|---|---|
| ![Recognition models](docs/screenshots/models.png) | ![Settings](docs/screenshots/settings.png) |

| App audio picker | Transcription progress |
|---|---|
| ![App picker](docs/screenshots/recording.png) | ![Progress](docs/screenshots/progress.png) |

> Screenshots come from an earlier build whose window title still reads
> `WhisperASR`; the product was renamed to SonicScribe afterwards (see the note
> at the top of this file).

---

## 🚀 Key Features

### 1. 🎙️ Versatile Multi-Engine ASR Architecture
Switch effortlessly between recognition engines according to your specific performance and accuracy requirements:

| Engine | Acceleration | Highlights & Use Cases |
|---|---|---|
| 🍎 **Apple Native Speech** | macOS SpeechAnalyzer | **Zero VRAM overhead, millisecond-level streaming response**; completely on-device & lightweight |
| ⚡ **Qwen3-ASR** | Metal GPU (transcribe.cpp) | 0.6B / 1.7B GGUF architectures; state-of-the-art accuracy on Chinese, dialects, and technical terminology |
| 🧠 **NVIDIA Nemotron 3.5** | Apple Neural Engine (Core ML) | Optimized for ANE with native punctuation across 40+ languages at ultra-low energy consumption |
| 🚀 **Whisper.cpp** | Metal GPU | Supports official Whisper Tiny to Large-v3 Turbo, as well as fine-tuned variants (e.g. Breeze-ASR) |
| 🎯 **FunASR** | Sherpa-ONNX (CPU/NEON) | SenseVoice-Small & Paraformer models with rich audio text representations and high noise robustness |
| 🌐 **Online API ASR** | Cloud Services | OpenAI Whisper API, Xiaomi MiMo ASR (with streaming chunk-by-chunk SSE return) |
| 🖥️ **Remote LAN ASR** | LAN GPU Servers | Direct connection to self-hosted faster-whisper / vLLM endpoints to offload local Mac hardware |

### 2. 🪟 Unified Floating Subtitle Overlay & Live Translation
- **Capsule-style Floating HUD**: Sleek borderless overlay integrating target app selection, microphone mixing toggle, recognition/translation switch, font/size controls, and window pin-on-top.
- **Simultaneous Bilingual Display**: Dual-layer rendering with typewriter-style streaming animation and automatic sentence-sealing alignment.
- **Context-Aware Error Self-Correction**: Translation prompt embeds context and phonetic error-correction heuristics to eliminate minor ASR typos from affecting translation quality.
- **Scenario-based Prompt Presets**: Built-in templates for "Video Subtitles", "Business Meetings", "Academic Lectures", and "Casual Chat" with dynamic template variables.
- **Zero-Setup Translation Backends**: Besides local LLM servers (LM Studio / Ollama) and OpenAI-compatible cloud APIs, three **key-free public channels** are built in — Google Translate v1 (`translate_a/single`), Google Translate v2 (`translate_a/t`), and Microsoft Translator (Bing web session). No account, no API key, no configuration: pick a channel and translation works.
- **OBS / Cleanfeed Streaming Mode**: Dedicated transparent and chroma-key (green screen) windows for live broadcasting.

### 3. 🔊 Smart Audio Capture & Neural Voice Activity Detection (VAD)
- **Application Audio Loopback**: Native ScreenCaptureKit audio interception per application without installing third-party virtual sound cards.
- **Dual-Channel Mixing**: Seamlessly mix application output with your microphone, complete with Zoom meeting end detection and automatic stop prompts.
- **Silero Neural VAD + Adaptive Noise Floor**: Combines Silero neural voice probability with Zero Crossing Rate (ZCR) and energy filters to adaptively estimate noise floors and cut at natural sentence valleys.
- **$O(1)$ Amortized Buffer Compaction**: High-concurrency, microsecond-level locked audio buffer, preventing drop frames even during multi-hour continuous recording.

### 4. 📝 Interactive Transcripts & AI Meeting Minutes
- **Interactive Audio Waveform Playback**: Text segments sync highlighted as audio plays; click any sentence to seek directly to that audio timestamp.
- **AI Meeting Minutes**: One-click extraction of key topics, decisions, and actionable items with customizable prompt templates and context token budgets.
- **Multi-Format Export**: Export standard `SRT`, `VTT` subtitles, `Markdown`, `TXT`, and `JSON` formats.

### 5. 🔌 Local OpenAI-Compatible API Server
Turn your Mac into an OpenAI-compatible speech transcription server for your local network:
- **Endpoints**:
  - `POST /v1/audio/transcriptions` (supports `json`, `verbose_json`, `text`, `srt`, `vtt`)
  - `POST /v1/audio/translations`
  - `GET /v1/models`
- **Drop-in Third-Party Integration**: Seamlessly connect Raycast, Immersive Translate, Bob, NextChat, ChatBox, and more to `http://127.0.0.1:8080/v1`.

---

## 🛠️ System Requirements

- **Operating System**: macOS 14.0 (Sonoma) or newer (macOS 15+ / 26 recommended for Apple Native Speech)
- **Hardware Architecture**: Apple Silicon Mac (M1 / M2 / M3 / M4 series)
- **Toolchain**: Xcode 15+ / Swift 5.9+

---

## 📦 Build & Run

### Quick Build with Swift Package Manager

```bash
# 1. Clone repository
git clone https://github.com/your-repo/SonicScribe.git
cd SonicScribe

# 2. Build release binary
# Requires the Xcode toolchain (SwiftUI macros live there). If `xcode-select -p`
# points at CommandLineTools, prefix with
# DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release

# 3. Launch SonicScribe
.build/release/WhisperASR
```

### Run Unit Test Suite (331 Test Cases)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

---

## 🧪 Testing & Benchmarking

Beyond the unit suite, the on-device engines can be driven and scored from any
MCP client through `Scripts/sonic_asr_mcp.py`:

| Tool | Purpose |
|---|---|
| `list_models` | Enumerate selectable engines with readiness, language coverage and blockers. `probe=true` actually loads each one and reports real load latency |
| `get_asr_status` | Engine readiness, model paths and the active configuration |
| `update_engine_config` | Hot-swap the engine and its hyper-parameters; unknown keys are rejected rather than silently ignored |
| `transcribe_file` | Single-pass transcription. `reference=` returns an in-band CER; `task="translate"` does speech translation to English (whisper engines only) |
| `stream_transcribe` | Replays a chunk arrival timeline (loss / jitter / reorder) and emits per-chunk partial and final events |
| `benchmark_models` | Cross-product of engines x audio files, returning load time, inference time, RTF, transcript and CER |

Which engines run depends on the files present under
`~/Library/Application Support/WhisperASR/Models`; `list_models(probe=true)`
reports what actually loads rather than what merely exists. The whisper engines
are driven through a `whisper-cli` binary — build it from the vendored
`.whisper.cpp` (`cmake -B build .whisper.cpp && cmake --build build -j --target
whisper-cli`) or point `WHISPER_CLI` at an existing one.

> **Note on the bundled benchmark corpus.** The seeded clips are *synthesised*
> speech-like waveforms — a syllable-rate amplitude envelope over formant tones
> plus a noise floor. They are deliberately **not** intelligible speech, which
> makes them useful for exercising the pipeline (chunking, packet loss, TTFT,
> end-of-utterance latency, flicker) and useless for measuring recognition
> accuracy: every engine scores a 100% error rate on them. For accuracy work
> use real recordings — `.transcribe.cpp/samples/` ships real speech in
> Chinese, Japanese, Korean, Cantonese, Russian, German and English.

---

## 📂 Project Architecture

```
SonicScribe/
├── Sources/
│   ├── App/                              # App entry point, global state & UI views
│   │   ├── WhisperASRApp.swift           # SwiftUI App entry & lifecycle setup
│   │   ├── AppState.swift                # Global @Observable reactive state management
│   │   ├── AppRuntimeManager.swift       # Runtime orchestrator for ASR, Translation & Subtitles
│   │   ├── ConfigurationManager.swift    # Centralized configuration persistence
│   │   ├── ContentView.swift             # Main container layout
│   │   ├── SidebarView.swift             # History sidebar
│   │   ├── DetailView.swift              # Transcript details & bilingual view
│   │   ├── PlayerView.swift              # Interactive audio playback controls
│   │   ├── MinutesWindowView.swift       # AI Meeting Minutes window
│   │   └── Settings/                     # Modular Settings Pages (7 sub-modules)
│   │       ├── GeneralSettingsPage.swift
│   │       ├── RecognitionSettingsPage.swift
│   │       ├── TranslationSettingsPage.swift
│   │       ├── CaptionSettingsPage.swift
│   │       ├── AudioSettingsPage.swift
│   │       ├── HistorySettingsPage.swift
│   │       └── SystemStatusSettingsPage.swift
│   └── Pipeline/                         # Core audio, ASR & subtitle pipelines
│       ├── ASR/                          # Multi-engine ASR providers and facade
│       │   ├── TranscriptionService.swift# Dispatching hub for all engines
│       │   ├── ASRManager.swift          # Live loop, watchdog & auto-degradation
│       │   ├── WhisperProvider.swift     # whisper.cpp (Metal) bridge
│       │   ├── QwenProvider.swift        # Qwen3-ASR backend (GGUF + Metal)
│       │   ├── NemotronProvider.swift    # NVIDIA Nemotron (Core ML / ANE)
│       │   ├── FunASR/                   # Sherpa-ONNX runtime & Paraformer / SenseVoice
│       │   ├── AppleServices/            # Native SpeechAnalyzer & TranslationSession
│       │   └── APIServer.swift           # OpenAI-compatible HTTP transcription server
│       ├── Audio/                        # Audio capture, resampling & VAD
│       │   ├── AudioRecorder.swift       # ScreenCaptureKit loopback & O(1) buffer
│       │   ├── AudioLoader.swift         # Multi-format decoding & chunked FFmpeg fallback
│       │   └── SherpaVAD.swift           # Silero neural VAD module
│       ├── Subtitle/                     # Live subtitle generation & HUD
│       │   ├── SubtitleManager.swift     # Partial/final state machine & ring buffer
│       │   ├── FloatingLetter/           # Unified floating capsule overlay
│       │   └── ObsSubtitleWindowController.swift # OBS green-screen output
│       ├── Translation/                  # Translation engine routing
│       │   ├── TranslationManager.swift  # Streaming & aligned batch translation
│       │   ├── TranslationService.swift  # OpenAI-compatible SSE client
│       │   └── PromptBuilder.swift       # Dynamic translation prompt template engine
│       └── History/                      # History storage & meeting minutes
│           ├── HistoryManager.swift      # In-memory history cache
│           ├── TranscriptionStore.swift  # Multicore parallel JSON loader
│           └── MeetingMinutesService.swift# LLM meeting minutes summarizer
├── Frameworks/                           # Prebuilt native XCFramework binaries
│   ├── CWhisper.xcframework              # whisper.cpp + Metal
│   ├── CTranscribe.xcframework           # transcribe.cpp (Qwen3-ASR Metal)
│   └── SherpaONNX.xcframework            # sherpa-onnx + onnxruntime
├── Tests/                                # Logic unit test suite (331 cases)
├── Scripts/                              # Build, release, icon & benchmark tooling
│   ├── build_release.sh                  # Release bundle; writes the brand variables into Info.plist
│   ├── build_whisper_lib.sh              # Rebuild CWhisper.xcframework
│   ├── build_transcribe_lib.sh           # Rebuild CTranscribe.xcframework
│   ├── convert_model.sh                  # Model format conversion helpers
│   ├── generate_icon.swift               # Programmatic app icon -> Assets/icon_1024.png
│   └── sonic_asr_mcp.py                  # MCP server exposing the on-device engines
└── docs/                                 # Architectural diagrams, specifications & handoffs
```

---

## 🔗 URL Scheme & Automation

SonicScribe can be triggered via macOS URL Scheme:

| Command | Description | Example |
|---|---|---|
| `sonicscribe://record?app=Zoom` | Auto-match app and start recording with live subtitles | `open "sonicscribe://record?app=Zoom&mic=true&translate=true"` |
| `sonicscribe://record` | Present the unified floating HUD with app picker | `open "sonicscribe://record"` |

The legacy `whisperasr://` scheme is registered alongside the new one, so existing
shortcuts keep working. The accepted schemes are read from `Info.plist`
(`CFBundleURLSchemes`, written by `Scripts/build_release.sh`) rather than hardcoded —
renaming the product only requires updating the build script's brand variables.

---

## 📄 License & Attribution

**SonicScribe is a derivative work of [whisperASR](https://github.com/plateaukao/whisperASR) and is licensed under the Apache License 2.0** — the same license as the upstream project. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Apache-2.0 is permissive, but it does **not** allow a derivative work to be relicensed on different terms. This project therefore stays Apache-2.0 and must not be described as MIT.

### Upstream lineage

| Repository | Role |
|---|---|
| [plateaukao/whisperASR](https://github.com/plateaukao/whisperASR) | Original project © Daniel Kao |
| [shimianmaifu11-collab/whisperASR](https://github.com/shimianmaifu11-collab/whisperASR) | Fork |
| [celiankk/whisperASR](https://github.com/celiankk/whisperASR) | Fork — this repository's `origin` |

Upstream's `LICENSE` is retained verbatim. Per Apache-2.0 §4(b), [NOTICE](NOTICE) records that the files here have been substantially modified — the rename to SonicScribe, the multi-engine ASR layer, the translation pipeline, the floating subtitle overlay, the settings reorganisation, the meeting-minutes service and the benchmark tooling are all additions or rewrites on top of the upstream work.

### Third-party components

| Component | License |
|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | MIT |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Apache 2.0 |
| [onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 |

Speech recognition models are downloaded at runtime and are not bundled with this repository. Each model carries its own terms — consult the model card before commercial use.
