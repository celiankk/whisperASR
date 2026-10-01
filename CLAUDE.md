# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# 需要 Xcode 工具链：项目用 SwiftUI 宏（`@State` 等），其实现只随 Xcode 提供。
# 若 `xcode-select -p` 指向 CommandLineTools，以下命令需加
# DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer 前缀。
# Scripts/build_release.sh 已内置自动回退，可直接运行。
swift build          # Build the project
swift run            # Build and launch the app
open Package.swift   # Open in Xcode (Cmd+R to run)
bash Scripts/build_release.sh   # Release app bundle -> SonicScribe.app
```

Test suite (XCTest, 331 tests; requires full Xcode, not just CLT):

```bash
DEVELOPER_DIR=/Applications/Xcode.app swift test
```

**只有 CommandLineTools 的环境也能构建与跑测试**——`Scripts/dev_build.sh` 已固化这条路径
（`swift build` 会因为缺 SwiftUI 宏实现而失败，脚本改为显式加载 Xcode 的宏插件）：

```bash
bash Scripts/dev_build.sh          # 构建
bash Scripts/dev_build.sh test     # 构建 + 跑 331 个测试（CLT 下用 xctest 运行器）
bash Scripts/dev_build.sh run      # 构建 + 启动 App
```

原理（改动该脚本前先读）：宏插件必须用 `-plugin-path` 加载，`-load-plugin-executable`
会把 dylib 当可执行文件启动（报 `cannot execute binary file` / `malformed response`）。
测试侧另需三组参数，缺一即失败：`-I <platform>/Developer/usr/lib`（XCTest 的 Swift 模块
接口在此，`XCTest.framework/Modules` 下只有 modulemap）、`-framework XCTest`、
`-lXCTestSwiftSupport`（`XCTAssert*` 的 Swift overlay 符号在此）。且本环境下
`swift test` 只会发现 swift-testing（0 用例）而漏掉 XCTest，故用 `xctest` 运行器直接跑
`.xctest` 包。

**After making code changes, always run `swift run &` in the background to launch the app so the user can verify the changes immediately.**

### First-time setup

The pre-built `Frameworks/CWhisper.xcframework` is included. To rebuild from source:
```bash
bash Scripts/build_whisper_lib.sh    # Builds whisper.cpp with Metal+Accelerate → xcframework
```

Convert the Breeze-ASR-25 model (requires Python 3 + torch/transformers/numpy/huggingface_hub):
```bash
bash Scripts/convert_model.sh        # Downloads ~3 GB model → Models/ggml-model.bin
```

### MCP 配置（`.mcp.json`）

两个 MCP server 的可执行文件与路径改为环境变量间接指定，不再硬编码某台机器的家目录
绝对路径（原实现写死 `/Users/hyj/Desktop/asrtest/.venv/bin/python` 与 asrtest 项目路径）：

- `ASR_WORKBENCH_PYTHON`：Python 解释器（默认 `python3`）。**原意图**是用 asrtest 项目的
  venv 解释器（含该 MCP server 的依赖）；需要 venv 时由使用者显式导出该变量。
- `ASR_WORKBENCH_DIR`：外部 `asr-workbench` 项目目录（默认 `.`）。
- `CLAUDE_PROJECT_DIR`：本仓库根目录（默认 `.`），用于定位 `Scripts/sonic_asr_mcp.py`。

JSON 无注释语法，故原意图记在此处。

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages:

```
<type>: <short summary>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `style`, `perf`, `test`, `build`, `ci`

Examples:
- `feat: add JSON persistence for transcriptions`
- `fix: restore pending items on app relaunch`
- `refactor: extract audio loading into AudioLoader`
- `docs: add CLAUDE.md`

For breaking changes, add `!` after the type: `feat!: change transcription storage format`

## Architecture

Native macOS SwiftUI app (macOS 14+, arm64) for offline/online speech transcription, live subtitles with translation, and an OpenAI-compatible local API. Built with Swift Package Manager.

> The project was rebranded to **声记 SonicScribe**; the Swift module, Application Support
> directory and log directory intentionally remain `WhisperASR` (no data migration).

### Pipeline layout

```
Sources/
├── App/          App shell: entry, AppState, ConfigurationManager, Settings pages,
│                 MenuBarController, Onboarding, DesignTokens, L10n, BackupService
└── Pipeline/
    ├── Audio/      采集与加载：AudioRecorder(SCStream+M4A)、AudioLoader、AudioPlayerManager、
    │               SherpaVAD(Silero)、SPSCFloatRingBuffer、RealtimeAudioIngest、ScreenCaptureMonitor
    ├── VAD/        RMS+ZCR 联合人声判定（VAD.swift）
    ├── ASR/        识别层：TranscriptionService 门面 → ASRProvider 多引擎
    │   │           Whisper / Qwen(Qwen3-ASR GGUF) / Nemotron(Core ML/ANE) /
    │   │           Online(OpenAI 兼容·MiMo·自定义) / Remote(局域网自托管) /
    │   │           Apple(SpeechAnalyzer) / FunASR(sherpa-onnx)
    │   ├── AppleServices/  原生 Speech + Translation 适配
    │   ├── Capability/     ASRCapability 能力描述层
    │   ├── FunASR/         sherpa-onnx 运行时
    │   ├── KVCache/        预留（未接线）
    │   ├── Model/          ModelCatalog / ModelDownloader / ModelPathResolver / GGUFInspector
    │   └── APIServer.swift OpenAI 兼容本地服务
    ├── Translation/ 翻译层：TranslationManager → TranslationProvider
    │               Local(LM Studio/Ollama) / Online(OpenAI 兼容) / Apple /
    │               Google v1 / Google v2 / 微软（后三条为免 API Key 公共通道）
    ├── Subtitle/    字幕：SubtitleManager(partial/final 状态机) + SubtitleEngine +
    │               FloatingLetter/(一体化悬浮窗 + Metal SDF 渲染器·未接线) + OBS 输出
    └── History/     历史：HistoryManager / TranscriptionStore(JSON 懒加载) /
                    TranscriptionIndexStore(SQLite·未接线) / OpusAudioArchiver(·未接线) /
                    MeetingMinutesService
```

### Data flow

`SidebarView`/`WorkbenchView` (drag-drop / picker / recording) → `AppState` → `AppRuntimeManager`
(async: `ASRManager` live loop, `TranslationManager`, `SubtitleManager`) →
`TranscriptionService.transcribe()/transcribeChunk()` → engine C/async API →
`ASRResultNormalizer` → `TranscriptionSegment` → persisted by `TranscriptionStore`.

### Key layers

- **ASR 门面 / 引擎路由** (`TranscriptionService`): 解析当前模型/引擎选择 → 对应 `ASRProvider`。
  引擎判定事实源 = `ASREngineSelection` + `ModelCatalog` 元数据 + GGUF 头部架构 + 目录语义。
  出口统一经 **`ASRResultNormalizer`** 归一为 `NormalizedASRResult`（字幕层禁止 `if engine` 分支）。
  流式（有状态）引擎通过 `isStreamingEngine` + `StreamingFeedWaterline` 做绝对采样水位线去重。

- **实时识别循环** (`ASRManager`): 拖动 `AudioRecorder` 累积的 16kHz PCM，自适应静音阈值
  （噪声底 × 系数 + Silero VAD 复核）、渐进式停顿、谷值回溯封口、tail 重转录、崩溃恢复快照、
  5s 健康检查与自动降级（连续 chunk 失败 → 探测 Apple 可用后才切）。

- **状态与配置**: `AppState`（`@Observable`，页面状态 + UI 状态）委托 `AppRuntimeManager`
  （`service` / `recognition` / `translation` / `subtitle`）。设置统一走
  `ConfigurationManager`（`general` / `asr` / `translation` / `subtitle` / `audio` / `window` / `asrPrompt`），
  `didSet` 持久化到 UserDefaults，键与历史版本兼容。

- **持久化** (`TranscriptionStore`): 每条一个 JSON，位于 `~/Library/Application Support/WhisperASR/Transcriptions/`。
  启动只载 `fullText`（列表/搜索够用），segments/译文本地懒加载（`hydrateTranscriptIfNeeded`）；
  **未 hydrate 的条目只允许 `saveMetadata`**（整体重存会用空数组清掉磁盘转录）。

- **音频** (`AudioLoader`): `AVAssetReader` 分块转 16kHz mono Float32；macOS 无法解码的容器
  （WebM/Opus 等）回落到 `ffmpeg`（`/opt/homebrew/bin` 等固定路径 + PATH）。

- **API 服务** (`APIServer`): 可选 OpenAI 兼容 HTTP 服务（[FlyingFox](https://github.com/swhitty/FlyingFox)）。
  复用 App 的单一 `TranscriptionService`（`attach`）；`POST /v1/audio/transcriptions`、
  `POST /v1/audio/translations`、`GET /v1/models`，支持 `json`/`verbose_json`/`text`/`srt`/`vtt`。
  可选 Bearer token、LAN 绑定 + Bonjour。`MultipartParser` 手写解析。

- **翻译** (`TranslationManager`): 按 `TranslationMode` 路由 `TranslationProvider`。
  实时整句翻译有界并发（上限 8）+ 10s 超时 + 3 连败降级为"仅识别"。免 key 通道
  （Google v1/v2、微软 Bing 会话）在 `FreeWebTranslationProvider`，非流式、零配置、
  自带 429 退避与会话刷新，不接受提示词/上下文。

### Model resolution

`ModelCatalog` 定义可下载模型（Breeze-ASR-25、Nemotron 3.5、whisper.cpp tiny~large-v3-turbo、
Qwen3-ASR 0.6B/1.7B、FunASR SenseVoice/Paraformer/Nano）；`ModelManager`（shared `@Observable`）
跟踪 `~/Library/Application Support/WhisperASR/Models/` 下的已下载文件、下载器与当前选择
（UserDefaults `"selectedModelFile"`）。

`ModelPathResolver.resolveModelPath()` 优先级：自定义 `"modelPath"` → `"selectedModelFile"` →
App Support 默认 `ggml-model.bin` → 项目内 `Models/ggml-model.bin`（经 `#filePath` 定位）。
**自定义路径优先**（用户在「自定义模型」里填的路径立即生效）；因此 `ModelManager.select()`
与 `downloadFinished()` 都会清空 `"modelPath"`，避免「列表显示使用中、实际生效的是旧自定义模型」。
模型按解析路径懒加载，切换模型下次转录即生效。

FunASR 目录模型的文件名清单事实源是 `FunASRModelConfig`（角色 → 备选路径），
而不是硬编码文件名：同一模型的发布批次会改文件名/位置（Fun-ASR-Nano 早期包
`encoder-adaptor.int8.onnx` + 根目录 tokenizer，2025-12 后为 `encoder_adaptor.int8.onnx`
+ `Qwen3-0.6B/` 目录），且 nano 的 tokenizer 必须是**目录**（含
`vocab.json`/`merges.txt`/`tokenizer.json`），传文件路径会被 sherpa-onnx 拒绝。
`ModelCatalog.isComplete` 与 `SherpaONNXRuntime.load` 都走 `FunASRModelConfig.resolve()`。

### 已知未接线（实现+单测齐全，但未进入运行时）

`SPSCFloatRingBuffer`/`RealtimeAudioIngest`、Metal SDF 字幕渲染器、`TranscriptionIndexStore`、
`OpusAudioArchiver`、`BoundedBatchTranslationManager`。详见 `docs/HANDOFF.md` 第 32 节。

