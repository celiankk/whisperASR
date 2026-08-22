# WhisperASR 项目状态总结（smartsteer-status）

> 更新日期：2026-08-09 ｜ 分支：重构整体 ｜ 构建：`swift build` 0 error / 0 warning ✅
> 平台：macOS 14+（SwiftPM，Swift 5.9 tools）｜ 最新提交：`ce44943 重构2`

---

## 1. 已完成内容

### 1.1 ASR Provider 抽象层（重构第一步）
- `ASRProvider` 协议：`prepare / loadModel / unloadModel / transcribeChunk / transcribeFile / status`
- 统一输出 `ASRResult`（text / isFinal / isPartial（派生）/ language / confidence / timestamp）+ `ASRProviderStatus`
- `ASRProviderEngine` 四引擎：`whisper / nemotron / qwen3asr / online`
- 适配层：`WhisperProvider`、`NemotronProvider`、`QwenProvider`（内部推理代码未动）
- `TranscriptionService` → Provider 调用关系改造完成

### 1.2 翻译 Provider 层（重构第二步）
- `TranslationProvider` 协议统一签名：`translate(_ request: TranslationRequest) async throws -> TranslationResult`
- `TranslationRequest`（texts / text / sourceLanguage / targetLanguage / previousTranslations，单句/批量两个 init）
- `TranslationResult`（texts / text（便捷拼接）/ language / sourceLanguage / targetLanguage / confidence）
- 两个实现：`LocalTranslationProvider`（LM Studio 本地）、`ChatCompletionProvider`（在线 API）
- `TranslationManager` 统一调度：按 `TranslationMode`（off / localModel / onlineAPI）分发，3 连败降级、10s 超时、队列上限 8
- `TranslationService`：自定义 system prompt、显式 `stream:false`、错误信息增强（URL/模型/状态码/响应体）
- `TranslationDebug` 日志：Session 创建、语言状态、耗时、错误

### 1.3 在线 ASR（OpenAI 兼容 + MiMo）
- `OnlineASRProvider`（实现 ASRProvider）+ `OnlineASRService` 独立网络层 + `OnlineASRBuffer` + `OnlineResultAccumulator`
- `OnlineASRApiType` 三种：**openai**（`/audio/transcriptions` multipart）/ **mimo**（`chat/completions` input_audio Base64 + api-key 头 + asr_options.language + 流式开关）/ **custom**（完整端点原样）
- 句子模式缓冲策略：最小 2s / 目标 2.5s / 停顿 0.4s 提前提交 / 上限 8s
- `normalizedBaseURL` 防 `/v1/v1` 重复、完整端点识别
- 错误日志含 URL / 状态码 / 响应体；`testConnection` 发送最小音频验证
- MiMo 指定语种（auto / zh / en）+ 流式/非流式开关（仅 MiMo 显示）

### 1.4 音频分片（ChunkManager）
- `AudioChunkingMode`：off / localOnly / onlineOnly；参数 1–10s（本地）/ 3–15s（在线）
- online 恒不参与（Provider 内句子模式避免双重聚合）

### 1.5 AppState 拆分
- `AppRuntimeManager`（service / ASRManager / TranslationManager / SubtitleManager / ModelManager / SystemMonitor）
- `AppState` 仅保留 UI 状态，UI 绑定兼容

### 1.6 统一配置（ConfigurationManager）
- `AppConfiguration` 六类配置 + `ConfigurationSchema` 版本迁移（currentVersion = 1）
- UserDefaults 键与 1.4 兼容；设置页全部绑定 ConfigurationManager

### 1.7 ASR Prompt 增强
- `ASRPromptManager` + `ASRPromptConfiguration`：enabled / source / customPrompt / sceneTemplate / keywords
- 手动 / 场景模板 / 历史词库 / AI 生成四种来源

### 1.8 Apple 原生服务（macOS 26 重新接入 ✅）
> 2026-08-09 完成「彻底删除」后，基于 macOS 26 SDK 从零重建（AppleServices/ 独立目录，
> 全新实现，无旧代码残留）。
- **`AppleServices/AppleSpeechEngine.swift`**：`SpeechAnalyzer`（actor）+ `SpeechTranscriber` + `AnalysisContext`
  - 生命周期：`start / append / finish / pause / resume / stop`（含 `cancelAndFinishNow`）
  - 状态机：idle / initializing / loadingLanguage / listening / processing / paused / unavailable / permissionDenied / error
  - `AppleSpeechDebug`：initDuration / languageLoadDuration / bufferCount / recognitionLatency / partialCount / finalCount / lastError
  - 增量模式：`prefixCount` + `waitForTextGrowth(after:timeout:)`（partial 直显，不等待 final）
  - ASRResult.language 填充会话解析后的 locale 标识（如 zh-CN）
- **`AppleServices/AppleSpeechManager.swift`**：ASRProvider 适配层（统一注册到 TranscriptionService）
  - 音频预处理（高通去直流 + 噪声底估计 + 增益）；文件转录（临时会话 + waitForFinal）
- **`AppleServices/AppleLanguageManager.swift`**：`SpeechTranscriber` + `DictationTranscriber` 的 installedLocales 并集，
  状态 Installed / Available / Need Download / Unavailable（不手写语言列表）
- **`AppleServices/AppleSpeechStatus.swift`**：权限封装（Speech Recognition + Microphone；识别不用 SFSpeechRecognizer，
  授权 API 仅有 requestAuthorization 故集中于此）+ @Observable 能力快照 + 本地识别细分状态
  （本地可用 / 需要下载资源 / 系统不支持 / 权限被拒绝 / 未授权，失败显示原因）
- **`AppleServices/AppleTranslationEngine.swift`**：`TranslationSession(installedSource:target:)` + `translations(from:)`
- **`AppleServices/AppleTranslationManager.swift`**：TranslationProvider 适配层（统一注册到 TranslationManager）
- **`AppleServices/AppleTranslationStatus.swift`**：`AppleTranslationDebug`（Session/语言/耗时/错误）+ @Observable 能力快照
  （Framework / 会话可创建性 / LanguageAvailability 语言资源）
- 设置页「Apple 服务」分类恢复：Speech（授权/服务/引擎/麦克风/语言资源/当前语言/本地识别+原因/权限跳转/调试）
  + Translation（系统支持/Framework/会话/语言资源/源语言/目标语言/翻译方式）
- 统一 Provider 注册（不绕过 Manager）：`TranscriptionService.appleProvider`（ASRManager 经 service 调度）、
  `TranslationManager.provider(for:)` 的 `.apple` 分支
- 音频链路：AudioCaptureManager → PCM Buffer → AppleSpeechEngine → SpeechAnalyzer → SpeechTranscriber → ASRResult
- 翻译链路：ASR Final → TranslationManager（按模式分发 Apple / Local / Online）→ 字幕译文

### 1.9 字幕链路修复
- 全链路日志：`[Audio] / [ASR] / [ASR Result] / [Subtitle Input] / [Subtitle] / [Subtitle Display] / [Renderer] / [Online ASR]`
- 删除时长/停顿设置，partial 直显、final 更新；`SubtitleDebug.bypassFilters` 一键排查

### 1.10 其他
- `SubtitleEngine`：150ms UI 刷新节流、环形缓冲、性能监控（内存/任务/队列/异常检测）
- `HistoryManager`：500 条上限、批量删除（跳过进行中）、录音移废纸篓
- 历史记录 200 条环形缓冲；`SubtitleHistoryManager` 去重

---

## 2. 当前代码结构

```
Sources/
├── ASRProvider.swift            ASRProvider 协议 + 四引擎枚举 + ASRResult/ASRProviderStatus
├── WhisperProvider.swift        本地 Whisper 适配层
├── NemotronProvider.swift       Nemotron（FluidAudio/CoreML/ANE）适配层
├── QwenProvider.swift           Qwen3-ASR 适配层（后端待集成）
├── OnlineASRProvider.swift      在线 ASR Provider（句子模式）
├── OnlineASRBuffer.swift        缓冲策略 + 结果累积器
├── OnlineASRService.swift       网络层（openai/mimo/custom 端点 + 错误增强）
├── AppleServices/              macOS 26 原生 Apple 服务（独立目录）
│   ├── AppleSpeechEngine.swift     SpeechAnalyzer/SpeechTranscriber/AnalysisContext 流式引擎
│   ├── AppleSpeechManager.swift    ASRProvider 适配层（增量模式/文件转录）
│   ├── AppleLanguageManager.swift  语言资源（Installed/Available/Need Download/Unavailable）
│   ├── AppleSpeechStatus.swift     权限封装 + 能力快照 + AppleSpeechDebug
│   ├── AppleTranslationEngine.swift TranslationSession 引擎 + AppleTranslationDebug
│   ├── AppleTranslationManager.swift TranslationProvider 适配层
│   └── AppleTranslationStatus.swift 翻译能力快照（Framework/会话/语言资源）
│
├── ASRManager.swift             实时识别循环（静音/封口/去重）+ 健康检查 + autoSave
├── TranslationManager.swift     翻译调度（超时/降级/队列）
├── TranslationProvider.swift    翻译协议 + TranslationRequest/Result
├── TranslationService.swift     OpenAI 兼容翻译实现
├── LocalTranslationProvider.swift / ChatCompletionProvider.swift
├── SubtitleManager.swift        字幕调度 → FloatingLetter
├── SubtitleEngine.swift         引擎生命周期 + 节流 + 性能监控 + 历史
├── AppRuntimeManager.swift      service/Manager 持有者
├── AppState.swift               仅 UI 状态
├── ConfigurationManager.swift   统一配置（六类 + 版本迁移）
├── ChunkManager.swift           音频分片（off/localOnly/onlineOnly）
├── ASRPromptManager.swift / ASRPromptConfiguration.swift
├── SystemMonitor.swift / HistoryManager.swift / ModelCatalog.swift / ModelDownloader.swift
├── AudioRecorder.swift / AudioLoader.swift / LanguageDetector.swift
├── TranscriptionService.swift / TranscriptionStore.swift / Models.swift
├── LocalModelManager.swift / ModelPathResolver.swift / GGUFInspector.swift
├── APIServer.swift              本地 OpenAI 兼容 API（FlyingFox）
├── MeetingMinutesService.swift / MinutesWindowView.swift
├── BackupService.swift / ScreenCaptureMonitor.swift / AudioPlayerManager.swift
├── AppLogger.swift              统一日志（分类环形缓冲）
└── SettingsPages.swift / SettingsView.swift / ContentView.swift / SidebarView.swift
    DetailView.swift / PlayerView.swift / ModelDownloadView.swift / ToastView.swift
    DebugSubtitleView.swift / WhisperASRApp.swift 等 UI

Sources/FloatingLetter/
├── FloatingLetterViewModel.swift    字幕状态机（partial 直显/bypass）
├── FloatingLetterIntegration.swift  pushState/observeState
├── SubtitleLayers.swift             SubtitleDebug + SpeechEndpointDetector
├── FloatingLetterViews.swift / FloatingLetterOverlayController.swift
└── FloatingAppPicker.swift / FloatingLetterLeakTest.swift

Scripts/build_release.sh         构建 app（Info.plist 含 NSMicrophone 权限描述）
```

**数据流：**
```
AudioCaptureManager → ASRManager → ASRProvider（whisper/nemotron/qwen/online）
      → ASRResult → SubtitleManager → SubtitleProcessor → Floating Window
句尾 → TranslationManager → TranslationProvider（local/online）→ 字幕译文
```

---

## 3. 关键参数

| 模块 | 参数 | 值 |
|---|---|---|
| ASRManager | 最大分片 | 30s（16000×30） |
| ASRManager | 强制分片 | 8s（16000×8） |
| OnlineASRBuffer | 最小发送 | 2.0s |
| OnlineASRBuffer | 目标时长 | 2.5s |
| OnlineASRBuffer | 停顿提前提交 | 0.4s |
| OnlineASRBuffer | 上限 | 8.0s |
| TranslationManager | 单句超时 | 10s |
| TranslationManager | 队列上限 | 8 |
| TranslationManager | 降级阈值 | 连续 3 次失败 |
| SubtitleEngine | UI 刷新节流 | 150ms |
| SubtitleHistoryManager | 历史上限 | 200 条 |
| TranscriptionHistoryManager | 上限 | 500 条 |
| ConfigurationManager | schema 版本 | 1 |
| APIServer | 默认端口 | 8080 |
| 音频 | 采样率 | 16kHz（Float） |
| 模型目录 | Application Support | WhisperASR/Models |

**模型目录**：Breeze-ASR-25（默认）、Nemotron 3.5 Multilingual（ANE）、Qwen3-ASR-1.7B、Whisper Large v3 Turbo / Medium / Small / Base / Tiny

---

## 4. 未解决问题

1. **Qwen3-ASR 推理后端未集成**：whisper.cpp 尚不支持 GGUF 音频架构，选择后仅能下载，推理报错（Qwen3ASRBackend 为占位，Qwen3SmokeTest 存在）
2. **MiMo 流式模式**：SSE 解析（parseMimoSSE）在长音频多 chunk 下的稳定性待真机验证
3. **在线 ASR 成本/延迟**：2s 最小缓冲在快速对话场景可能截断首句，暂无自动调节
4. **字幕去重边界**：说话停顿小于 400ms 时相邻重复词的去除依赖 ASR 自身输出
5. **性能监控阈值**：内存增长 80MB/2min 阈值、队列 >5 判异常为经验值，未长期观察校准
6. **FloatingWindow 多屏/多 App 追踪**：ScreenCaptureMonitor 与 FloatingAppPicker 的组合场景覆盖不全
7. **历史记录音频文件占用**：500 条上限下磁盘占用无压缩/清理策略（仅删记录时移废纸篓）

---

## 5. 下一步建议

### 短期（验证与收尾）
1. **真机回归测试**（当前最高优先级）：
   - 本地 / 在线翻译两模式切换统一 TranslationRequest/Result 链路
   - 权限引导流程（麦克风首次授权 → 拒绝 → 系统设置跳转）
2. 验证 MiMo 流式 vs 非流式在真实网络下的字幕延迟

### 中期（功能补齐）
4. **Qwen3-ASR 后端集成**（transcribe.cpp 路线，all-in-one GGUF 已就绪）
5. 在线 ASR 缓冲**动态调节**（按说话速率自适应 2s 下限）
7. 历史记录**磁盘占用统计**与定期清理策略

### 长期（架构演进）
8. 全链路**统一测试套件**（Provider mock + 端到端字幕链路）
9. 日志分级与**导出诊断包**（一键收集 DebugStats + 全链路日志便于排查）
10. 多引擎**并发对比模式**（同一音频同时跑两个引擎用于精度评估）

---

*维护提示：每步修改后执行 `swift build` + `bash Scripts/build_release.sh` 验证；日志统一走 AppLogger 分类；Provider 接口保持向后兼容。*
