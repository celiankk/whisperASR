# WhisperASR

[繁體中文](README.zh-TW.md)

A native macOS app for audio transcription using [Breeze-ASR-25](https://github.com/mtkresearch/Breeze-ASR-25) (Whisper large-v2 fine-tuned for Taiwanese Mandarin and code-switching) via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Metal GPU acceleration.

![Live transcription with bilingual output](docs/screenshots/live_recording.png)

## Screenshots

| Transcription Progress | Bilingual Transcript |
|---|---|
| ![Progress](docs/screenshots/progress.png) | ![Transcript](docs/screenshots/transcript.png) |

| App Picker | Settings |
|---|---|
| ![App picker](docs/screenshots/recording.png) | ![Settings](docs/screenshots/settings.png) |

## Features

### Live transcription + translation

- **App audio recording** — capture audio from any running app via ScreenCaptureKit (M4A/AAC at 48 kHz)
- **Live transcription** — see transcribed text in real-time while recording
- **Live translation** — per-segment translation displayed inline below each transcribed line, via OpenAI-compatible API
- **Smart auto-scroll** — live transcription view automatically follows new segments
- **Live results reuse** — when recording stops, live transcription results are kept (no re-transcription)
- **Zoom meeting detection** — automatically prompts to stop recording when a Zoom meeting ends

### File transcription

- **Drag-and-drop** audio/video files (MP3, WAV, M4A, MP4, AAC, FLAC, OGG, WMA, AIFF, CAF)
- **Batch processing** — queue multiple files at once
- **Sequential transcription queue** — files wait in queue and transcribe one at a time

### Bilingual output

- **Post-transcription translation** — translate completed transcriptions into any configured language with a single click
- **Configurable languages** — auto-detect or set source language; choose target language for translation
- **Search** — global sidebar filter across all transcriptions, plus in-file find (Cmd+F) with match highlighting and navigation

### Playback

- **Audio playback** with play/pause, seek bar, and skip ±5s controls
- **Synced text highlighting** — the current sentence highlights as audio plays
- **Click-to-seek** — click any segment to jump to that point in the audio

### Privacy & performance

- **Metal GPU acceleration** via whisper.cpp — fully on-device, no audio ever leaves your Mac
- **Bring your own API** — translation uses any OpenAI-compatible endpoint, including local models
- **Re-transcribe** and **retry on failure** with copyable error messages
- **Custom model path** — configure via Settings

## Requirements

- macOS 14.0+
- Apple Silicon Mac (arm64) — the included xcframework is built for arm64
- Python 3 with `torch`, `transformers`, `numpy`, `huggingface_hub` (only if converting the model yourself; not needed if downloading the pre-converted GGML file)

## Setup

### 1. Build whisper.cpp (if not already included)

The repo includes a pre-built `CWhisper.xcframework`. To rebuild it from source:

```bash
bash Scripts/build_whisper_lib.sh
```

This clones whisper.cpp, builds it with Metal + Accelerate, and packages the static libraries into an xcframework.

### 2. Get the Breeze-ASR-25 GGML model

**Option A (recommended):** Download the pre-converted GGML file directly from HuggingFace (~3 GB) and place it at `Models/ggml-model.bin`:

```
https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/blob/main/ggml-model.bin
```

**Option B:** Convert from the original model (requires Python 3 + `torch`, `transformers`, `numpy`, `huggingface_hub`):

```bash
bash Scripts/convert_model.sh
```

This downloads the Breeze-ASR-25 model from HuggingFace, clones the necessary repos, and converts it to GGML format at `Models/ggml-model.bin`.

### 3. Build and run

```bash
swift build
swift run
```

Or open in Xcode:

```bash
open Package.swift
```

Then build and run from Xcode (Cmd+R).

### 4. Build release app bundle (optional)

```bash
bash Scripts/build_release.sh
```

This builds an optimized release binary, generates a proper `.icns` icon, and packages everything into `WhisperASR.app` with Info.plist. To install:

```bash
cp -r WhisperASR.app /Applications/
```

If macOS blocks the app with a "cannot be opened" warning (because it is not signed), run the following command with the path to wherever `WhisperASR.app` is located:

```bash
xattr -cr /path/to/WhisperASR.app
```

## Usage

1. **Add files** — drag audio/video files onto the sidebar, or click the **+** button
2. **Record app audio** — click the record button, select a running app, and start recording; recently used apps are listed first
3. **Live transcription & translation** — enable live transcription in the recording dialog to see text as you record; set a target language in Settings to see inline translations below each segment
4. **Wait for transcription** — files are queued and transcribed one at a time with progress and ETA
5. **Review** — click a completed item to see the transcript with timestamps
6. **Translate** — click the translate button to translate a completed transcription into any configured language
7. **Search** — use the sidebar search bar to filter across all files, or press Cmd+F to find within a transcript
8. **Play audio** — use the player controls at the bottom; text highlights in sync
9. **Export** — click the export button (top-right) to save as SRT or plain text

### Settings

Open **Settings** (Cmd+,) to configure:

- **Target Language** — choose a language to translate transcriptions into
- **OpenAI Translation API** — only the API key is required; endpoint defaults to OpenAI, model defaults to `gpt-4o-mini`. Any OpenAI-compatible endpoint (including local models) works.
- **Whisper Model** — path to a custom `ggml-*.bin` model file; defaults to `Models/ggml-model.bin` in the project directory

## Project Structure

```
Sources/
├── WhisperASRApp.swift        # App entry point
├── ContentView.swift          # NavigationSplitView layout
├── SidebarView.swift          # File list with drag-and-drop & context menu
├── DetailView.swift           # Transcript display, progress, export
├── PlayerView.swift           # Audio playback controls
├── RecordingView.swift        # App audio recording UI
├── AudioRecorder.swift        # ScreenCaptureKit audio capture
├── AppState.swift             # App state management & transcription queue
├── Models.swift               # Data models
├── TranscriptionService.swift # whisper.cpp C API integration
├── TranslationService.swift   # OpenAI-compatible translation API
├── TranscriptionStore.swift   # JSON file-per-item persistence
├── AudioLoader.swift          # AVAssetReader audio loading
├── AudioPlayerManager.swift   # AVPlayer wrapper
├── AppIconGenerator.swift     # Programmatic app icon rendering
└── SettingsView.swift         # Language, translation & model settings
Scripts/
├── build_whisper_lib.sh       # Build whisper.cpp xcframework
├── convert_model.sh           # Convert HuggingFace model to GGML
└── build_release.sh           # Build release .app bundle with icon
Frameworks/
└── CWhisper.xcframework/      # Pre-built whisper.cpp static library
```

## License

This project uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and the [Breeze-ASR-25](https://github.com/mtkresearch/Breeze-ASR-25) model by MediaTek Research.
