# WhisperASR / Apple Services Bugfix 交接文档

- 交接时间：2026-08-23 06:50 CST（第 23.4 节为最新交接）
- 项目目录：`/Users/hyj/Desktop/whisperASR_副本`
- Git 分支：`重构整体`
- 当前 HEAD：`ce44943 重构2`
- 工作区状态：**有大量已暂存 + 未暂存修改，尚未提交**（涵盖第 10–15 节全部改动）
- 本文档位置：`HANDOFFtmd/HANDOFF.md`

---

## 1. 这个会话在做什么

用户要求“检查 bug 并修复”。当前仓库正处于一次较大的重构后：新增了 macOS 26 原生 Apple Services 能力，包括：

- Apple Speech ASR：`SpeechAnalyzer` / `SpeechTranscriber`
- Apple Translation：`TranslationSession`
- 设置页新增「Apple 服务」
- `TranscriptionService` / `TranslationManager` 接入 `.apple` provider
- 字幕浮层状态机为 Apple 引擎做了部分适配

本次会话的重点是审查这些新接入代码中的逻辑 bug，并做修复。不是从零开发新功能。

---

## 2. 已完成内容

### A. Apple Speech 授权超时修复

文件：

- `Sources/AppleServices/AppleSpeechStatus.swift`

问题：

原实现用 `withThrowingTaskGroup` 做 30 秒授权超时竞速：

```swift
group.addTask {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { ... }
    }
}
```

但 `SFSpeechRecognizer.requestAuthorization` 的回调不会响应 task cancellation。如果系统弹窗一直不出现或用户不操作，task group 仍会等待那个永远挂起的子任务，所谓 30 秒超时实际会永久挂起。

修复：

改用 `AsyncStream` 竞速：

```swift
private static func requestAuthorization(
    timeout seconds: Double
) async -> SFSpeechRecognizerAuthorizationStatus? {
    let stream = AsyncStream<SFSpeechRecognizerAuthorizationStatus> { continuation in
        Task { @MainActor in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.yield(status)
                continuation.finish()
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(seconds))
            continuation.finish()
        }
    }

    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}
```

要点：

- 超时任务调用 `continuation.finish()` 后，等待方立即拿到 `nil`
- 回调迟到时 `yield` 会返回 terminated，不会崩溃
- 已用独立 Swift 脚本验证过类似 AsyncStream 模式：挂起回调场景 1 秒返回 nil；正常回调场景能收到值

---

### B. Apple Translation Engine 状态覆盖 bug 修复

文件：

- `Sources/AppleServices/AppleTranslationEngine.swift`

问题：

原代码：

```swift
state = .initializing
defer { state = .available }
```

即使翻译失败、catch 里已经设置 `state = .error`，函数退出时 `defer` 又会把它覆盖成 `.available`。

修复：

移除错误的 `defer`，改为成功路径显式置 `.available`，失败路径保持 `.error`。

---

### C. Apple Translation Status 低版本状态误报修复

文件：

- `Sources/AppleServices/AppleTranslationStatus.swift`

问题：

macOS 15–25 没有程序化 `TranslationSession`，但旧逻辑里如果语言包 installed 且 `sessionAvailable == false`，会返回 `.error`。这不是初始化失败，而是系统不支持程序化翻译。

修复：

综合状态改为：

```swift
if !sessionAvailable {
    state = .unavailable
} else if languageStatus == .supported {
    state = .needResource
} else if languageStatus == .installed {
    state = .available
} else {
    state = .unavailable
}
```

---

### D. FloatingLetter 字幕状态机跨会话残留修复

文件：

- `Sources/FloatingLetter/FloatingLetterViewModel.swift`

问题：

新增了两个状态：

```swift
private var lastSentenceFinalText = ""
private var lastTranslationRequestSource = ""
```

但 `resetSubtitleDisplay()` 没有重置它们。后果是：

- 上一场录制结束后，`lastSentenceFinalText` 仍保留最后一句
- 新录制会话第一句如果与上一场末句相同，会被误判成“已经处理过”
- 结果可能既不显示，也不触发翻译

修复：

在 `resetSubtitleDisplay()` 中加入：

```swift
lastSentenceFinalText = ""
lastTranslationRequestSource = ""
```

---

### E. Apple Speech 文件转录只返回一个 final 的严重 bug 修复

文件：

- `Sources/AppleServices/AppleSpeechEngine.swift`
- `Sources/AppleServices/AppleSpeechManager.swift`

问题：

原实现：

```swift
let result = await fileEngine.waitForFinal(timeout: 20)
```

而 `waitForFinal()` 只要看到第一个 final 就返回。同时 engine 内部只保存最后一个 `lastFinal`。对多句音频文件来说，这会导致只拿到一句或最后一句，丢失完整转录结果。

修复：

1. 新增 `finalResults: [ASRResult]`
2. 文件转录模式才收集 final，实时模式默认不收集，避免长时间录音内存无限增长
3. 新增：

```swift
func waitForFinalResults(timeout: Double) async -> [ASRResult]
```

4. 等 `resultsStreamEnded && analyzerStreamEnded` 都结束后再聚合
5. `AppleSpeechManager.transcribeFile` 用 `makeTranscriptionResult(from:)` 把多个 final segment 聚合成完整 `TranscriptionResult`

另外：

- 文件转录的输入流缓冲从 `.bufferingNewest(12)` 改成 `.unbounded`
- 原因：文件转录会一次性快速喂入全部音频，`bufferingNewest(12)` 可能在 analyzer 消费不及时时丢前面的音频

---

### F. Apple Speech 音频时间戳漂移修复

文件：

- `Sources/AppleServices/AppleSpeechEngine.swift`

问题：

原代码：

```swift
cumulativeSamples += Int64(samples.count)
```

但如果 `SpeechAnalyzer.bestAvailableAudioFormat` 返回的格式与源 16kHz 格式不同，`convertBuffer` 后实际送入 analyzer 的帧数不一定等于原始 `samples.count`，时间轴会漂移。

修复：

```swift
cumulativeSamples += Int64(inputBuffer.frameLength)
```

即按实际送入 analyzer 的帧数推进时间戳。

---

### G. Apple Speech Manager 生命周期与幂等修复

文件：

- `Sources/AppleServices/AppleSpeechManager.swift`

修复点：

1. `prepare()` 幂等：
   - 已有 running engine 直接 return
   - stale engine 先 stop 再替换

2. `unloadModel()` 防覆盖竞态：
   - 原来是先 `await speechEngine?.stop()`，再 `speechEngine = nil`
   - stop 期间如果有新会话启动，最后 `speechEngine = nil` 可能把新会话清掉
   - 改为先摘除引用，再异步 stop：

```swift
let engine = speechEngine
speechEngine = nil
await engine?.stop()
```

3. `transcribeChunk()` 对 stale engine 处理：
   - 只有 `existing.isRunning` 才复用
   - 否则 stop stale 并懒启动新会话

4. `status()` 判断改成 engine 实际 running，而不是仅非 nil

---

### H. macOS 版本判断顺序修复

文件：

- `Sources/AppleServices/AppleSpeechManager.swift`

问题：

原逻辑在低版本 macOS 上也会先请求语音识别授权，然后才报“需要 macOS 26+”，用户体验错误。

修复：

`prepare()` / `transcribeChunk()` / `transcribeFile()` 都先检查：

```swift
guard #available(macOS 26, *) else {
    throw AppleSpeechError.unavailable("Apple Speech 需要 macOS 26+")
}
```

然后再请求授权或启动引擎。

---

### I. 文件转录尊重 language 参数

文件：

- `Sources/AppleServices/AppleSpeechManager.swift`

原来 `transcribeFile(fileURL:language:...)` 忽略 `language`，固定使用 Apple Speech 设置里的 locale。

现在：

```swift
let requestedLocale = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let localeIdentifier = requestedLocale.isEmpty ? Self.localeIdentifier : requestedLocale
```

`language` 为空时仍回落到配置语言。

已验证本机 `SpeechTranscriber.supportedLocale(equivalentTo:)` 可以解析：

```text
en      -> en_US
zh      -> zh_CN
zh-CN   -> zh_CN
zh_CN   -> zh_CN
zh-Hans -> zh_CN
ja      -> ja_JP
ko      -> ko_KR
ru      -> ru_RU
```

---

### J. 系统状态页 Apple 翻译“重新连接”误走 OpenAI 修复

文件：

- `Sources/SettingsPages.swift`

问题：

`SystemStatusSettingsView.reconnectTranslation()` 原来对所有非 off/local 模式都调用：

```swift
TranslationService.translateSegmentsWithOpenAI(..., local: false)
```

当翻译方式是 `.apple` 时，它会错误地发 OpenAI 兼容请求，而不是检测 Apple Translation。

修复：

`.apple` 分支改为：

```swift
let status = await TranslationManager.testConnection(for: .apple)
```

并按 `TranslationConnectionStatus` 显示 connected / notConfigured / failed。

---

### K. 权限设置跳转面板修正

文件：

- `Sources/AppleServices/AppleSpeechStatus.swift`

问题：

`openSystemSettings()` 固定打开 Speech Recognition 面板。如果只是麦克风权限被拒，用户点按钮会进入错误页面。

修复：

只缺麦克风权限且语音识别权限正常时，打开 `Privacy_Microphone`；否则打开 `Privacy_SpeechRecognition`。

---

## 3. 当前验证状态

已执行并通过：

```bash
swift build
swift build -c release
bash Scripts/build_release.sh
```

结果：

- debug 构建通过
- release 构建通过
- `WhisperASR.app` 已重新生成
- 应用启动冒烟测试通过，无崩溃
- 启动日志显示 Apple Speech / Apple Translation 状态检测正常

当前仍有构建 warning，但不是本次引入的错误：

- whisper.cpp / transcribe.cpp 静态库是为 macOS 26 编译的，链接目标仍是 macOS 14，产生大量 ld warning
- 少量 Swift 6 concurrency mode warning，例如 `NSLock.lock()` 在 async context 的警告
- FluidAudio 有 unhandled resource warning

这些 warning 不阻塞当前构建。

---

## 4. 当前卡在哪 / 未完成事项

### 4.1 还没有真实录音链路回归

目前只完成了编译和启动冒烟测试，还没有做真实场景验证：

- Apple Speech 实时识别是否稳定出字
- Apple Translation 是否正确触发
- 多句连续说话、停顿封口、字幕翻译是否正常
- 文件转录多句是否能得到完整文本
- 权限首次弹窗、拒绝后再进入设置页的流程
- 语言包缺失 / 下载 / 安装后的行为

这是下一步最高优先级。

### 4.2 ~~Apple 实时识别架构仍有疑点，需要真机确认~~（已修复，见第 10 节 Bug L1）

tail 重转录与 Apple 流式引擎的重复喂音冲突已通过「绝对采样区间 + 喂音水位线」修复（2026-08-22 第二轮会话）。真实录音回归仍需执行，但架构层面的重复喂音已消除。

### 4.3 工作区尚未提交

当前有大量 staged + unstaged 变更。不要直接假设工作区干净。

建议后续先跑一遍真实回归，再决定是否拆分提交：

- Apple Services 重构基础
- 本次 bugfix
- 设置页 / UI 改动
- 日志 redirect / runtime refresh 等杂项

---

## 5. 下一步计划

按优先级：

### 5.1 真实功能回归

必须手动测：

1. Apple Speech 实时识别
   - 选择识别引擎 Apple
   - 授权首次弹窗
   - 中文 / 英文短句
   - 连续说话
   - 停顿后字幕封口
   - 长时间录制观察内存和 CPU

2. Apple Translation
   - 翻译方式选 Apple
   - 目标语言选择
   - 实时字幕原文 + 译文
   - 连续句子翻译是否串句
   - macOS 26 上 `TranslationSession` 是否可用

3. Apple Speech 文件转录
   - 用多句音频文件测试
   - 确认 segments 和 fullText 包含全部句子
   - 确认没有只返回最后一句

4. 设置页
   - Apple 服务页状态刷新
   - 当前语言选择
   - 未安装语言展示
   - 授权按钮
   - 打开系统权限设置按钮
   - 系统状态页 Apple 翻译检测 / 重新连接

5. 低版本兼容
   - 如有 macOS 14 / 15 环境，确认 Apple 引擎选择时不会先弹权限，而是明确提示需要 macOS 26+

### 5.2 观察 Apple live pipeline

重点看日志：

```text
[Audio] chunk generated ...
[ASR] request start ...
[ASR] response received ...
[ASR Result] provider=apple ...
[Subtitle Input] liveSegments ...
[Renderer] pushState ...
[Renderer] updateSubtitleState ...
AppleSpeechEngine: result final=...
```

特别关注：

- 同一段语音是否被重复喂给 Apple engine
- partial 是否不断累积成错误长句
- final 是否被提前当成完整句翻译
- 停顿封口后是否出现重复文本

如果发现重复喂音问题，下一步应考虑给 Apple Speech 做专门的 live streaming path，而不是继续硬套 ASRManager 的 tail re-transcription 模型。

### 5.3 提交整理

真实回归通过后，建议整理提交。可以考虑拆分：

1. `feat(apple-services): add native Apple Speech and Translation providers`
2. `fix(apple-services): fix authorization timeout, lifecycle and file transcription aggregation`
3. `fix(subtitle): reset sentence translation markers across sessions`
4. `fix(settings): route Apple translation reconnect through Apple provider`
5. `chore(build): add speech recognition usage description`

也可以合并成一个较大的 Apple Services bugfix commit，但不要把无关 UI / build 改动混得太乱。

---

## 6. 绝对不要踩的坑

这一节最重要。

### 坑 1：不要用 task group 给不可取消回调做超时

不要写这种模式：

```swift
try? await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
        await withCheckedContinuation { cont in
            SomeAPI.callback { cont.resume(returning: $0) }
        }
    }

    group.addTask {
        try await Task.sleep(...)
        throw CancellationError()
    }

    let result = try await group.next()!
    group.cancelAll()
    return result
}
```

如果 callback 不响应 cancellation，task group 退出前仍会等待子任务完成，所谓 timeout 会永久挂起。

本项目里 `SFSpeechRecognizer.requestAuthorization` 就是这种 API。

正确做法是用 `AsyncStream`，超时任务直接 `continuation.finish()`。

---

### 坑 2：不要用 `defer { state = .available }` 包整个可失败函数

这种写法会让失败路径的状态也被覆盖：

```swift
state = .initializing
defer { state = .available }

do {
    ...
} catch {
    state = .error
    throw error
}
// defer 又把 state 改回 available
```

成功和失败要显式设置终态。

---

### 坑 3：文件转录不能拿第一个 final 就返回

`SpeechTranscriber` 可能按语音段多次输出 final。不要只保存 / 返回单个 `lastFinal`。

文件转录必须收集全部 final，等 analyzer / results stream 结束后聚合。

同时注意：

- 实时会话不要无限收集 final，否则长时间录音内存会涨
- 本项目当前方案是 `start(collectFinalResults: true)` 只给文件转录开启

---

### 坑 4：文件转录不要用 `bufferingNewest(12)`

实时流为了背压可以用有限缓冲，但文件转录是一次性快速喂入全部音频。用 `bufferingNewest(12)` 可能丢前面的 audio buffer。

文件转录当前使用：

```swift
bufferingPolicy: .unbounded
```

---

### 坑 5：不要忽略 `AnalyzerInput.bufferStartTime`

不要把所有 chunk 的 `bufferStartTime` 都传 `.zero`。

这会让 analyzer 认为音频都在 0 时刻重叠，可能导致识别异常或无结果。

也不要简单用原始 `samples.count` 累积时间戳；要用转换后实际送入 analyzer 的 `inputBuffer.frameLength`。

---

### 坑 6：Apple Speech engine 生命周期要先摘引用再 stop

不要这样：

```swift
await speechEngine?.stop()
speechEngine = nil
```

stop 可能耗时。期间如果新会话启动并写入 `speechEngine`，最后 `speechEngine = nil` 会把新会话清掉。

正确顺序：

```swift
let engine = speechEngine
speechEngine = nil
await engine?.stop()
```

---

### 坑 7：低版本 macOS 不要先请求权限再报 unavailable

Apple Speech 新 API 需要 macOS 26+。所有入口应先：

```swift
guard #available(macOS 26, *) else {
    throw AppleSpeechError.unavailable("Apple Speech 需要 macOS 26+")
}
```

再请求授权或创建 engine。

否则 macOS 14 / 15 用户会先看到无意义的权限弹窗，然后才被告知系统不支持。

---

### 坑 8：Apple Translation 状态不能用固定版本推断语言资源

不要只用 `#available(macOS 15, *)` 或 `macOS 26, *` 决定语言包是否可用。

要用：

- `LanguageAvailability.status(from:to:)`
- 多候选 source language
- `sessionAvailable` 单独判断

并且注意：

- macOS 15–25 没有 programmatic `TranslationSession`
- 这种情况应报 `.unavailable`，不是 `.error`

---

### 坑 9：Apple 翻译的“重新连接”不能发 OpenAI 请求

`TranslationMode.apple` 不是 HTTP API。

系统状态页或任何 test connection 入口都必须走：

```swift
TranslationManager.provider(for: .apple).testConnection()
```

或：

```swift
TranslationManager.testConnection(for: .apple)
```

不要复用 local / online 的 `translateSegmentsWithOpenAI` 逻辑。

---

### 坑 10：字幕状态机的跨会话 marker 必须重置

`FloatingLetterViewModel` 里这些字段是有状态的：

```swift
lastSentenceFinalText
lastTranslationRequestSource
sentenceDeduplicator
detector
```

清空字幕 / 结束录制 / 新会话开始时，必须一起 reset。

否则上一场的最后一句会影响下一场第一句的显示和翻译。

---

### 坑 11：不要假设 Apple Speech 和 Whisper 的 chunk 语义相同

Whisper provider 适合 ASRManager 的 tail re-transcription：

- 每次重新转录未封口 tail
- overlap 后去重

Apple Speech 是持续流式 analyzer：

- 音频应该持续 append
- 不能随意重复喂同一段音频

当前代码做了部分适配，但没有经过真实录音充分验证。改动这块前一定要先看日志确认现有行为。

---

### 坑 12：不要把构建 warning 当成本次错误

当前构建 warning 主要包括：

- whisper / transcribe static libs built for macOS 26 but linked to macOS 14
- Swift 6 concurrency warnings
- FluidAudio resource warning

它们不影响当前 debug / release 构建。不要为了消 warning 盲目改 deployment target 或并发模型，除非明确理解影响。

---

### 坑 13：本项目没有正式单元测试 target

不要指望 `swift test` 能覆盖这些修复。

当前验证手段主要是：

```bash
swift build
swift build -c release
bash Scripts/build_release.sh
open WhisperASR.app
```

以及看日志：

```bash
tail -f ~/Library/Logs/WhisperASR/app.log
```

---

## 7. 关键文件索引

本次重点涉及：

```text
Sources/AppleServices/AppleSpeechEngine.swift
Sources/AppleServices/AppleSpeechManager.swift
Sources/AppleServices/AppleSpeechStatus.swift
Sources/AppleServices/AppleTranslationEngine.swift
Sources/AppleServices/AppleTranslationStatus.swift
Sources/FloatingLetter/FloatingLetterViewModel.swift
Sources/SettingsPages.swift
Sources/TranscriptionService.swift
Sources/TranslationManager.swift
Sources/ConfigurationManager.swift
Scripts/build_release.sh
```

相关入口：

- Apple Speech Provider：`AppleSpeechManager.shared`
- Apple Translation Provider：`AppleTranslationManager`
- ASR 统一调度：`TranscriptionService`
- 翻译统一调度：`TranslationManager`
- 实时识别循环：`ASRManager.startLive(recorder:)`
- 字幕浮层桥接：`FloatingLetterOverlayBinder`
- 设置页 Apple 服务：`AppleServicesSettingsView`

---

## 8. 快速命令

构建 debug：

```bash
swift build
```

构建 release：

```bash
swift build -c release
```

打包 app：

```bash
bash Scripts/build_release.sh
```

运行：

```bash
open WhisperASR.app
```

查看日志：

```bash
tail -f ~/Library/Logs/WhisperASR/app.log
```

查看进程：

```bash
pgrep -fl '/WhisperASR.app/Contents/MacOS/WhisperASR'
```

杀掉冒烟测试进程：

```bash
pkill -f '/WhisperASR.app/Contents/MacOS/WhisperASR'
```

---

## 9. 一句话总结

这次会话完成了一轮 Apple Services 重构后的 bug review 和修复，重点是授权超时、生命周期、文件转录聚合、翻译状态机、字幕跨会话残留和设置页 Apple 分支。编译、release 打包和启动冒烟都通过；但 Apple Speech 实时链路还需要真实录音回归，尤其是 ASRManager tail re-transcription 与 Apple streaming engine 的语义匹配问题。

---

## 10. 第二轮会话（2026-08-22）：4.2 疑点确认属实 + 5 个新 bug 修复

上一节 A–K 修复核对后均已落地。本轮确认 4.2 的担忧是真实 bug，并另发现 4 个问题，全部修复完毕。

### L1（主要）ASRManager tail 重转录重复喂音给 Apple 流式引擎

**确认**：ASRManager 每轮把未封口 tail `[tailStart, totalSamples)` 整段发给
`service.transcribeChunk(samples:)`（`Sources/ASRManager.swift`）。Whisper 等无状态引擎
重转录无副作用；但 `AppleSpeechManager.transcribeChunk` 对整段 chunk 调
`engine.append(samples:)` —— tail 只有在封口后才收缩，连续轮次区间大量重叠，
同一段音频被重复喂给同一个 `SpeechAnalyzer` 多次 → 识别文本重复、时间轴混乱。

**修复**（绝对采样区间 + 喂音水位线，精确去重、无音频指纹启发式）：

1. `ASRProvider` 协议新增 `transcribeChunk(samples:absoluteRange:)`
   （`Range<Int>?` = AudioRecorder.accumulatedSampleCount 绝对坐标），
   extension 默认实现转发到旧方法 —— 无状态引擎零改动；
2. `TranscriptionService.transcribeChunk` 透传区间；聚合（ChunkManager）路径
   位置失效，透传 nil；
3. `ASRManager` 调用处传 `tailStart..<totalSamples`；
4. `AppleSpeechManager` 新增 `liveFedAbsoluteSamples` 水位线
   （stateLock 保护）：每轮只 append `max(range.lowerBound, fedUntil)` 之后的
   新增采样；新会话启动 / unloadModel / cancelPending 时重置 nil；
   无区间的调用（理论路径）保守全量喂入并清空水位线。

关键场景验证（推演）：
- 连续多轮不封口：只喂每轮新增部分；
- 静音跳过路径（sealSilence 不喂静音）：下轮 feedFrom = 封口边界，静音段正确跳过；
- 强制封口后的 1s context 重发：引擎已持有该音频，水位线保证不重喂。

### L2 Apple 增量文本被误做 overlap 裁剪

强制封口后 `useOverlap=true`，`appendTail` 会对 tail 文本做 `trimOverlap`。
Apple 返回的是纯增量文本（引擎侧已按共同前缀对齐），没有音频 overlap，
裁剪可能误吃首字符。修复：`TranscriptionService.liveEngineStreamsIncrementally`
（Apple 为 true），ASRManager 据此对 Apple 关闭 overlap 裁剪。

### L3 文件转录固定 20s 超时对长音频不够

`waitForFinalResults(timeout: 20)` 在分析未完成时提前返回已收集的 final
（不完整且静默）。修复：超时 = `max(20s, 音频时长 × 2)`。

### L4 Apple 翻译重试复用失败的 TranslationSession

失败重试用同一个 session —— 已失效的 session 大概率再抛同一错误。
修复：重试路径新建 `TranslationSession`。

### L5 AVAudioConverter 每块新建

`AppleSpeechEngine.append` 每次调用新建 converter：重采样时滤波器历史每块
被重置，块边界产生伪影影响识别。修复：会话级共享 converter（start 创建、
stop 清理、append 内锁保护复用）；目标格式即 16kHz Float32 时直通不转换。

### 验证状态

- `swift build` / `swift build -c release` / `bash Scripts/build_release.sh` 全部通过
- 改动文件零新增 Swift warning（既有 warning 见坑 12）
- 启动冒烟通过：Apple Speech / Translation 状态检测正常
- **真实录音回归仍未执行**（见 4.1），水位线去重的实际效果需真机确认，
  重点观察日志中同一段音频是否只出现一次识别增量

### 新坑 14：流式引擎收到重叠 chunk 时必须按绝对水位线去重

任何新增的流式（有状态）ASR provider 接入 ASRManager 循环时，不能假设
`transcribeChunk(samples:)` 的音频是「全新」的。必须实现带
`absoluteRange` 的变体并做水位线去重，否则必然重复喂音。

---

## 11. 第三轮会话（2026-08-22）：修复「Apple 识别退出软件卡死」

### 现场证据（app.log，stdout 已设 _IONBF 无缓冲，日志可信）

```
02:02:05.999  Live transcription stopped          ← 停录（13.7 分钟录音），引擎正常停止
02:02:06.018  Overlay dismissed / 音频已保存
02:02:06~     最终文件转录启动（Apple 引擎，Task.detached）
02:02:10.215  ERROR live transcription chunk CancellationError   ← 停录后 4.2s 才报出
02:02:18.873  Live transcription stopped          ← 用户退出（applicationWillTerminate）
（之后无任何日志 —— 应用卡死，用户强杀）
```

### 根因

**取消后的忙转（100% CPU）**：`waitForTextGrowth` / `waitForFinalResults`
用 `try? await Task.sleep(...)` 轮询。任务被取消后 `Task.sleep` **立即**抛
CancellationError 且 `try?` 吞掉异常、不再挂起 → 循环退化成无挂起点的
高频自旋，直到 wall-clock 超时才停。

- 停录路径：实测自旋 4.2s（= 5s 超时耗尽才报 CancellationError）；
- 退出路径：`AppState.shutdown()` 先 `transcriptionQueueTask?.cancel()`，
  正在跑的 Apple 文件转录立即进入自旋——超时已被改为「时长×2」，
  13.7 分钟录音 = 最长 27 分钟满核自旋，贯穿整个退出流程；
  高速 malloc churn + speech XPC 清理交互导致进程无法退出（卡死）。

次要风险：`SpeechAnalyzer.cancelAndFinishNow()` 与 speech 进程（XPC）交互，
服务无响应时可能长时间不返回，`stop()` 无界等待。

### 修复

1. **轮询循环取消感知**（`AppleSpeechEngine`）：
   `try await Task.sleep` + catch 立即返回 / break，循环顶补
   `Task.isCancelled` 检查。取消后毫秒级退出，不再自旋。
   （这也让 ASRManager.withTimeout 的 task group 能立刻收尾——
   之前操作子任务卡满 5s 超时才让 group 结束。）
2. **stop() 有界化**：`cancelAndFinishNow` 与 3s 超时竞速
   （AsyncStream 模式，同坑 1 的正确做法）。超时则记日志、放弃干净
   teardown，teardown 任务留在后台，调用方（停录/退出/unloadModel）必定返回。
3. **transcribeFile 全路径兜底**：do/catch 包裹 start→feed→wait，
   失败/取消都 `await fileEngine.stop()`（有界），不再泄漏 analyzer；
   取消时 `Task.checkCancellation()` 抛出，不把残缺结果标记为完成。

### 验证

- debug / release / build_release.sh / 启动冒烟全部通过；
- 「退出卡死」需真机复现验证：Apple 引擎录一段 → 停录 → 立刻 ⌘Q，
  确认进程秒退（此前卡死场景：停录后文件转录进行中退出）。

### 新坑 15：async 轮询循环里绝对不要 `try? await Task.sleep`

```swift
while Date() < deadline {
    ...
    try? await Task.sleep(for: .milliseconds(100))   // 取消后立即抛、被吞 → 忙转
}
```

正确写法：

```swift
while Date() < deadline {
    ...
    if Task.isCancelled { break }
    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
}
```

任何「await 一个可能挂起/不可取消的操作」的场景，都要用 AsyncStream
竞速（finish 立即放行等待方），不能用 task group（见坑 1）。
注意 `TranslationManager.withTimeout` / `ASRManager.withTimeout` 仍是
task group 模式——它们靠操作自身响应取消来收尾（Apple 路径现已保证），
whisper/翻译 provider 若存在不可取消的挂起点，同样有此隐患，改动前先看日志。

---

## 12. 第四轮会话（2026-08-22）：修复「视频停止后字幕闪烁刷新」+ 刷新逻辑重构

### Q：Apple 识别现在是流式输出吗？

是。`AppleSpeechEngine` 持续把音频喂给同一个 `SpeechAnalyzer`，
`waitForTextGrowth` 每轮只返回新增文本（partial 立即上字幕，不等 final）；
配合第三轮的「水位线去重」，每个 pass 的增量是纯追加的。

### 闪烁根因（静音时的循环）

1. 句子完成后 `scheduleIdleClear` 到期 → `resetSubtitleDisplay()` 清屏，
   **同时清掉了 `sentenceDeduplicator` / `lastSentenceFinalText` /
   `lastProcessedInputSignature`（把输入处理记忆当显示状态清了）**；
2. ASRManager 静音路径每秒推送相同封口快照 → `pushState` 把最后一段
   封口句当 interim 传入 → 记忆已被清空 → 同一句被重新判定为新句 →
   重新渲染 + 重新请求翻译（译文区清空再出现）→ 再被空闲清除清掉 →
   无限循环 = 周期性闪烁（周期 ≈ subtitleClearDelay + 1s）；
3. 次要：相同输入每次都重走完成/检测/渲染路径（无输入级幂等）；
   `renderText` 对行数不变的更新也包 0.18s 动画，流式高频输出时抖动。

### 重构后的刷新逻辑（幂等原则：显示 = 输入的纯函数）

`FloatingLetterViewModel`：

1. **输入级幂等门**：快照签名（final 各行 id/文本/译文 + interim）相同 →
   直接跳过（不渲染、不重启计时、不重走检测）。译文异步到达会改变签名，
   正常放行；
2. **完成信号只认「新 final 文本」**：`newest.text != lastSentenceFinalText`
   （去掉 `interimText.isEmpty ||` 子句——相同文本的重复推送永远不是新句）；
3. **回声抑制**：`interimText == lastSentenceFinalText`（静音封口后封口句
   被顶替为 interim 推送）不作为新句渲染，保持当前显示直到空闲清除；
4. **resetSubtitleDisplay(clearMemory:)**：空闲清除只清画面（false），
   会话结束才清记忆（true）——闪烁循环的根；
5. **renderText**：行数不变（打字增长）不加动画；仅 1→2 行变化用动画；
6. **setTranslationResult**：画面已被空闲清除时丢弃迟到译文
   （`renderer.text.isEmpty` 检查），避免译文在空屏上单独冒出。

### 验证

debug / release / build_release.sh / 启动冒烟通过。
真机需验证：视频/音频停止后字幕应稳定显示最后一句 → 空闲延迟后
平滑消失 → 不再闪回；连续说话时逐字增长无抖动；暂停冻结/恢复正常。

### 注意

第四轮冒烟测试时误杀了用户正在运行的录制会话（`open` 激活已有实例 +
`pkill` 清场）——**冒烟测试前先确认没有正在录制的实例**；实时转录有
live_recovery.json 自动保存（≤2s），下次启动可恢复。

---

## 13. 第五轮会话（2026-08-22）：修复「Apple 字幕显示太慢」（延迟 5.5s → 亚秒）

### 日志实锤（app.log 引擎 partial 节奏）

```
02:45:03.225-03.263  字符级 partial 连续爆发（毫秒间隔）
02:45:09.144-09.184  下一次爆发        ← 间隔 5.88s
02:45:14.759-14.796  再一次爆发        ← 间隔 5.58s
```

爆发间隔 ≈ 5.0s（waitForTextGrowth 超时）+ 0.25s（循环 sleep）+ 0.3s
（新音频累积 guard），完美吻合。

### 根因：互相等待的饥饿死锁

ASRManager 循环喂音后**串行等待 transcribeChunk 返回**，而
`waitForTextGrowth` 在引擎没出字时等满 5s；Apple 引擎是流式的——
**没有新音频就不出字**。于是「上层等出字、引擎等喂音」，只有 5s 超时
解锁 → 5 秒积累的音频一次性喂入 → 引擎毫秒级爆发处理完（日志可见一次
吐出整段 5 秒歌词的字符级 partial）→ 再等 5s。字幕延迟 5.5~6s。

### 修复（延迟优先）

1. `AppleSpeechManager.transcribeChunk`：常规等待窗口 5.0s → **0.25s**
   （尾部静音断句场景保留 1.0s 取完整句）。文本没到尽快返回空，循环
   继续「喂音」；下一轮 pass 进入 waitForTextGrowth 时先零延迟检查
   已到文本再考虑等待——不丢字。
2. `ASRManager` 启动阈值按引擎区分：流式引擎（Apple）最小新音频
   0.3s → **0.1s**、最小 tail 0.5s → **0.2s**（`liveEngineStreamsIncrementally`
   判定）；无状态引擎（whisper 等）保持原阈值（每轮重转录整个 tail，
   阈值太小会白算）。

修复后 pass 周期 ≈ 0.5s：喂音延迟 ~0.25s + 引擎识别 ~0.15s +
UI 节流 0.15s（SubtitleUpdateScheduler）→ 端到端 ~0.5s 量级。
显示层幂等门（第 12 节）保证空结果 pass 不会引起闪烁。

### 待真机验证

重启应用（新构建）后：连续说话/放歌时字幕应亚秒级逐字出现，不再
数秒一跳；句尾停顿后封口与翻译触发时机正常。

### 新坑 16：流式引擎的「等待出字」窗口不能长于喂音周期

任何「喂音 → 等出字」串行循环里，等待窗口若长于一个喂音周期，引擎
就会断粮：流式引擎没音频不出字，等待方又因无字而干等——延迟被放大
到等待窗口全长。等待窗口应 ≤ 循环周期（本项目 0.25s），或把喂音与
取字解耦成独立任务。

---

## 14. 第六轮会话（2026-08-22）：断句优化（VAD 断句 + 增量累积）

### 用户反馈

延迟修复后「显示太快，无法理解是一句话」——逐字 dribble + 句子碎片化。

### 三个根因

1. **Apple 增量文本跨 pass 丢失（最严重）**：`appendTail` 每轮用
   「sealed + 本轮增量」重建显示——增量引擎当前句的前半部分下一轮就被
   丢弃，interim 永远只剩最新几个字；封口（seal）同样只固化最新增量。
   日志实锤：sealed 段全是 "My"、"H been" 这类单词碎片。
2. **VAD 封口对短句失效**：`cut - sealedSampleCount >= 8000`（0.5s
   最低语音量）——"好。""明白。"这类短句的停顿永远不封口，多句连成
   run-on。
3. **连续无停顿语音（唱歌）没有断句手段**：Apple 中文识别无标点，
   标点断句永不触发；无 VAD 停顿 → 全靠 8s 强制封口 → 滚屏。

### 修复

1. `SubtitleManager`：新增 `pendingTailSegments`（单一合并段 = 当前句）：
   - `appendTail(incremental: true)`（Apple）：本轮增量并入 pendingTail
     （跨 pass 累积，中西文智能拼接），合并为单一「当前句」段——
     interim 显示 = 完整当前句；
   - 全量引擎（whisper）：整段替换 pendingTail（原行为）；
   - `seal()`：sealTime 之后的段留作 pendingTail（下一句起点不丢）；
   - `sealSilence()`：静音路径不再丢文本——未提交的 pendingTail
     一并固化（否则静音封口时最后一句前半部分丢失）。
2. `ASRManager`：`appendTail` 传 `incremental: streamingEngine`；
   VAD 封口最低语音量 8000 → 1600（0.1s，短句也能独立成句）。
3. `SpeechEndpointDetector`：长度兜底断句——无标点连续语音超长
   （中文 28 字 / 西文 70 字）时在后半句最后一个软断点（，、；：,;空格）
   后断开成句，剩余部分经 lastEndedText 前缀衔接逻辑自然成为新句。
4. `FloatingLetterViewModel`：逐字 partial 渲染最小 0.3s 节流
   （合并字符 dribble；sentenceEnded / final 完成路径不受节流）。

### 断句信号优先级（修复后）

停顿 VAD（≥300ms 静音封口，主信号，停顿即成句+触发翻译）
→ 标点（。？！.?!）
→ 长度兜底（连续语音防滚屏）
→ 8s 强制封口（最后兜底）

### 待真机验证

重启应用后：正常说话 → 当前句完整逐字增长（不是碎片）、停顿即成句
并触发翻译；短句（"好。"）独立成句；唱歌/连续语音按 ~1 行断句不滚屏。

### 新坑 17：增量引擎的显示层必须跨 pass 累积

增量 provider（只返回新增文本）接入按「全量重转录」设计的显示层时，
任何「用本轮结果直接重建」的地方（快照、封口、翻译触发）都会丢前半句。
必须区分 incremental / 全量两种语义（`appendTail(incremental:)`），
增量走累积合并，全量走替换。

---

## 15. 第七轮长会话（2026-08-22 04:30–06:15）：UI/交互重构 + 内存优化 + 平滑度

### 我们在做什么

在第 10–14 节（Apple Services bug 修复、卡死修复、字幕闪烁/延迟/断句）之后的
连续 UI/交互迭代会话，用户逐条提需求，全部完成并逐轮重启验证。

### 已完成（按时间顺序，全部构建打包通过）

**A. 设置页识别配置重构**
- 引擎选择器简化为三项：**本地模型 / 在线 / Apple**（本地=自动判定
  Whisper/Qwen/Nemotron；`enginePickerSelection` 归一旧强制值；
  `TranscriptionService` 内部 6 case 枚举不动）
- 三种方式**严格互斥**：本地→语音识别模型+自定义模型+本地模型管理三区
  （本地范畴整体置顶）；在线→在线识别 API；Apple→Apple Speech；
  通用区（音频处理/ASR Prompt/识别语言）恒显
- 抽出可复用组件：`ModelCatalogSection` / `CustomModelSection` /
  `LocalModelsSection` / `OnlineASRSection` / `AppleSpeechSettingsSection`
  （Apple 服务页与识别页共用同一组件）
- 「识别语言」按引擎显示：whisper/nemotron/在线 → 语言选择器（whisper.cpp
  全语言表）；Qwen → 自动检测说明；Apple → 语言包说明

**B. 识别语言接线（新配置 asrLanguage，默认 auto）**
- `ASRConfiguration.asrLanguage` + `effectiveASRLanguage`（nil=自动）
- 文件转录：TranscriptionService 显式参数优先，未传时应用配置
  （whisper/nemotron/online；Apple 不套用——它有自己的语言包选择器）
- 实时链路：WhisperProvider.transcribeChunk 传语言；NemotronProvider
  变化时 setLanguage（lastLiveLanguage 缓存）；OnlineASR 透传
  （MiMo 内部把不支持语种映射回 auto）

**C. 字幕浮窗原生鼠标输入**
- 面板 borderless → **titled + resizable + fullSizeContentView + 透明标题栏
  + 隐藏标题/窗口按钮**（视觉不变，四边四角原生缩放、系统光标）
- 删除自制 resize 机器（40×40 角热区、自定义对角光标、手动帧计算、
  CADisplayLink 提交、SubtitleWindowManager 的 resize 会话 API）
- live-resize 生命周期：拖拽中每帧同步容器（字幕实时重排），
  didEndLiveResize 落盘 + 锁尺寸签名（防弹回）
- 背景×键盘：dismiss() 防御——先停 movableByWindowBackground 与
  ignoresMouseEvents 再 orderOut（防系统鼠标跟踪会话残留）

**D. 浮窗视觉/交互**
- 背景**合一**：panelBackground 用 subtitleBackgroundOpacity（整窗唯一一层；
  内层容器的背景/描边移除——此前双层叠加导致字幕区与外围透明度不符）
- 功能区**收起按钮**（chevron，右下角「结束录制」一侧）：收起时胶囊收缩为
  只包住按钮（钉在右侧，不残留条带）；状态持久化；与 5 秒自动隐藏独立
- 字幕平滑度：活跃行（末行）用 `SplitSubtitleText` 逐字入场（公共前缀 diff，
  旧字静态新字淡入上移 12pt/0.32s/错峰 45ms）；渲染节流 0.3→0.2s；
  译文淡入；空闲清除 0.25s 淡出
- **左对齐修复**：SubtitleFlowLayout 增加 textAlignment 参数（原先
  placeSubviews 硬编码 midX 居中，把左对齐设置盖掉）；SplitSubtitleText
  透传；VM 默认 .leading

**E. 录制流程语义重构（重要）**
- 「转录」开关改为「**转录记录**」：只控制录制结束后是否生成历史条目；
  **实时字幕/翻译始终进行**（onConfirmRecording 无条件启动实时链路）
- 关闭时：finishRecording 跳过历史创建并删除录音文件；
  崩溃恢复快照（live_recovery.json）不写（防下次启动恢复成历史条目）
- 翻译方式保护：`lastActiveTranslationMode` 记住用户配置
  （Apple/本地/在线），开关翻译不再硬编码 onlineAPI、关转录不再清空方式
- 选择 App 页：转录记录/翻译/麦克风三开关 + 转录模型选择（恒显示）
- 主窗口：设置页左上「‹ 返回转录」按钮；「选择」按钮移到转录列表搜索行

**F. 内存优化 + 死代码清理**
- **历史懒加载**：启动只载 fullText（搜索/列表够用），segments/译文在
  打开详情/翻译/生成纪要时 hydrate（`TranscriptionItem.hydrateTranscriptIfNeeded`）；
  未 hydrate 条目 save 走 `saveMetadata`（读盘改元数据回写，防空 segments
  覆盖磁盘）；转录完成置 transcriptHydrated=true 再整体保存
- 删除死代码约 300 行：SubtitleProcessor / StreamingSubtitleBuffer +
  SubtitleBufferMerge / SubtitleHistoryBuffer / ASREngineSelection.label /
  ControlVisibility.hover / AppleSpeechEngine 的 pause/resume/isPaused/lastFinal

**G. 解耦合修复**
- FloatingLetterViewModel.renderText 移除对 FloatingLetterOverlayController
  的反向引用（VM 不感知窗口控制器）
- 「转录记录已关闭」角标从字幕层整体移除（liveTranscriptionOff 删除）——
  显示层保持输入纯函数原则
- 全链路组件关系审查（桥接层/Views/SubtitleLayers/SubtitleManager/
  Provider 协议）——详见第 14 节后补的审查结论，无其他反向耦合

### 当前卡在哪 / 待验证

1. **关闭浮窗鼠标卡死**：只做了 dismiss 防御修复（最可能路径），**未复现
   验证**。用户曾报告"关闭字幕浮窗软件还开着会卡住 mac 鼠标导致点击不了"。
   若仍复现：需要用户提供精确操作序列 + 卡死时 `sample <pid>` 采主线程栈。
2. **真实录音回归仍未做**（贯穿全部轮次）：Apple 实时字幕+翻译长跑、
   断句手感（VAD 封口/长度兜底）、逐字动画流畅度、文件转录完整性。
3. **懒加载历史回归**：打开旧条目/翻译/重命名后重启应用确认元数据保留。
4. **工作区全部未提交**——见下一步的拆分建议。

### 下一步计划

1. 真机回归：录制（转录记录开/关两种）、字幕断句/平滑度/左对齐、
   关浮窗鼠标、历史懒加载读改写、长录音内存曲线
2. 提交拆分建议：
   - `feat(ui): settings engine selection 3-way + exclusive sections + language selection`
   - `feat(overlay): native mouse input + unified background + collapsible controls`
   - `feat(recording): transcription-record toggle semantics + translation mode preservation`
   - `perf(history): lazy transcript hydration + dead code removal`
   - `feat(subtitle): per-char typing animation + left alignment fix`
3. 可选后续：AudioLoader 长文件流式加载（当前整文件载内存，13 分钟≈50MB
   瞬时）；AudioRecorder.getSamples 每轮尾拷贝复用缓冲（分配器压力）

### 快速验证命令（不变）

```bash
swift build && swift build -c release && bash Scripts/build_release.sh
open WhisperASR.app
tail -f ~/Library/Logs/WhisperASR/app.log
```

### 新坑 18：自绘 Layout 不要硬编码对齐

`SubtitleFlowLayout.placeSubviews` 硬编码 `bounds.midX - width/2` 居中，
导致新接入的逐字动画行无视「左对齐」设置。任何自绘 Layout/渲染组件的
对齐必须参数化传递；给现有组件加对齐时默认值保持旧行为（默认 .center），
调用方显式传入。

### 新坑 19：开关语义变更必须审计全部消费点

`enableLiveTranscription` 语义从「实时转录」改为「生成转录记录」时，
所有引用点都要重新核对：onConfirmRecording 启动条件、finishRecording
历史创建、崩溃恢复快照、通用设置开关文案、URL handler、选择 App 页
绑定、pushState 派生。漏一处就是静默行为错误（如恢复快照把纯实时录制
变成历史条目）。

### 新坑 20：懒加载条目禁止整体重存

未 hydrate 的历史条目内存里 segments 为空——`HistoryManager.save` 必须
路由到 `saveMetadata`（读盘改元数据回写）；**转录完成/翻译完成等产生
完整内容的路径必须先置 `transcriptHydrated = true`** 再 save，否则
整体保存会用空数组清掉磁盘上的转录内容（数据丢失级 bug）。

### 新坑 21：业务状态不得耦合进字幕显示层

「转录记录已关闭」角标曾被塞进 subtitleArea——显示层必须是输入
（final+interim）的纯函数，任何业务状态提示要在显示层之外（或经输入
通道传入）。同理 VM 不得反向引用窗口控制器。

### 新坑 22：Swift 不可用的 ObjC 私有 API

`endLiveResize()` 虽有文档但 Swift 不可见（编译错误"no member"）。
`beginLiveResize/endLiveResize` 配对调用不要用；结束 live-resize 场景
用 `inLiveResize` 判断 + 通知监听（didEndLiveResizeNotification）实现。

---

## 16. 第八轮会话（2026-08-22 06:20–07:05）：测试体系 + 流式解码

### 已完成

**A. 单元测试体系从零建立（40 个测试全绿）**

项目此前没有任何测试（坑 13）。新增 `Tests/WhisperASRTests/`：

| 测试文件 | 覆盖 |
|---|---|
| SubtitleManagerTests (11) | pendingTail 增量累积/中西文拼接/空 pass 不丢、封口提交+留存、静音封口固化、trimOverlap |
| SpeechEndpointDetectorTests (10) | 标点断句/单轮完整句立即成句/回声忽略/前缀衔接、长度兜底（中文软断点/硬切/西文阈值）、reset |
| SubtitleDeduplicatorTests (5) | 抑制/合并/回溯/刷新/窗口过期 |
| SubtitleSplitterTests (5) | 行数上限/末尾保留/内容完整性/西文词边界/标点优先断行 |
| SubtitleLanguageTests (4) | 中/俄/其他/CJK 标点归类 |
| ASRConfigurationLanguageTests (4) | effectiveASRLanguage 归一规则 |

运行方式：`DEVELOPER_DIR=/Applications/Xcode.app swift test`
（**必须带 DEVELOPER_DIR**——系统 xcode-select 指向 CommandLineTools，
无 XCTest 模块；Xcode.app 已装。）

**B. 测试立刻修出 2 个真 bug（检测器首轮路径）**
`SpeechEndpointDetector.update()` 的 `sentenceText.isEmpty` 分支提前
return，跳过标点与长度检查：
1. 引擎单轮推出完整带句号的句（VAD 封口后 Apple final 常见）→ 要等
   下一轮才成句 → **翻译延迟一轮**；
2. 超长无标点句单轮到达 → **长度兜底完全失效**。
修复：统一走标点/长度检查（首轮也生效）。测试的调用模式必须模拟真实
管线（每轮推完整累积文本，非逐字 delta）。

**C. AudioLoader 流式分块解码（长文件内存优化）**
- 新 API `loadSamplesChunked(url:chunkSamples:onChunk:)`：
  AVFoundation 路径凑满一块（默认 30s=480k samples）即回调，消费方
  边收边喂；返回 false 可提前终止；
- `loadSamples` 变为薄包装（聚合全部块），旧调用方不受影响；
- ffmpeg 路径保持整读后按块回调（进程管道无原生流式价值）；
- `AppleSpeechManager.transcribeFile` 改为流式喂入：不再持有全量 samples
  （13 分钟录音 ≈50MB ×2 峰值 → 单块 ≈1.9MB）；超时时长改由引擎水位线
  取（`AppleSpeechEngine.totalAudioDuration()`）。

### 验证状态

- `swift test`：40/40 通过
- debug / release / 打包通过，应用已重启（新构建）
- **未做真机回归**：Apple 文件转录（流式路径）需用多句音频文件验证完整性；
  断句器首轮成句修复需真机确认翻译触发时机

### 新坑 23：写测试前先确认真实调用模式

初版断句器测试按「逐字 delta」构造输入，与真实管线（每轮推完整累积文本）
不符，6 个假失败掩盖了 2 个真 bug。先读调用方（ASRManager 的 pendingTail
语义）再设计测试输入；测试失败时要区分「假设错」与「实现错」，两者都要处理。

### 新坑 24：CommandLineTools 无 XCTest

`xcode-select -p` 指向 CommandLineTools 时 `swift test` 报 no such module
'XCTest'。本机装有 Xcode.app，用 `DEVELOPER_DIR=/Applications/Xcode.app
swift test` 运行；不要 `sudo xcode-select -s` 改系统配置。

---

### 一句话总结（第 15 节）

第七轮完成了设置页三项引擎重构、识别语言选择、浮窗原生鼠标输入与视觉
合一、转录记录语义重构（实时字幕始终进行）、历史懒加载省内存、逐字
平滑动画与左对齐修复；全部构建打包通过。遗留：真实录音回归、鼠标卡死
复现验证、以及海量未提交变更的拆分提交。\n---

## 17. 第九轮会话（2026-08-22 06:40–07:20）：对标 LiveTranslate 全量改造 + 管线分层重构

### 我们在做什么

对标 LiveTranslate（Windows 实时翻译，547★）的全部可借鉴项（12 项）一次性落地，
同时按用户要求把代码组织重构为「单文件模块 + 管线分层」扁平结构。

### A. 结构重组（环节 0）

```
Sources/
├── App/                          # 应用壳：入口/主窗口/设置/配置/菜单栏/i18n
├── Pipeline/
│   ├── Audio/                    # 环节1 采集与加载（Recorder/Loader/Player/Monitor）
│   ├── VAD/VAD.swift             # 环节2 语音活动检测（新文件，RMS+ZCR 联合）
│   ├── ASR/                      # 环节3 识别（providers/engines/模型管理/APIServer/AppleServices/）
│   ├── Translation/              # 环节4 翻译（providers/service/manager）
│   ├── Subtitle/                 # 环节5 字幕（Manager/Engine/FloatingLetter//图层）
│   └── History/                  # 环节6 历史（Manager/Store/纪要）
```
git mv 移动（同 SwiftPM target 内零编译影响）。66 文件归位，一次构建通过。

### B. 功能落地（环节 1–12，全部完成）

1. **流式翻译输出**：TranslationService SSE 逐 token（performStreamingRequest，
   delta.content 喂回调，reasoning 丢弃）→ 协议 translateStreaming（默认回退非流式）
   → TranslationManager.translateSentenceStreaming → AppState 流式入口 →
   VM.appendTranslationDelta（译文逐字上屏，0.12s 节流，定稿 setTranslationResult）
2. **思考模式兼容**：thinkingControlBody 按模型名注入禁思考参数
   （Qwen/GLM/vLLM: chat_template_kwargs.enable_thinking=false；
   OpenAI/Grok: reasoning_effort=none）；extractContent 思考分离（content 空
   取 reasoning 尾段）；设置页「思考模式：自动/强制禁用/不发送」
3. **双下载源**：ModelDownloader.DownloadSource.rewrite（hf ↔ hf-mirror.com
   域名替换，对 file/hfFolder/目录 API 全生效）；设置页「下载源：官方直连/国内镜像」
4. **JSON 批量翻译**：>1 句要求 JSON 数组输出；parseTranslationArray
   （剥 markdown 围栏、取首 [ 末 ]、句数校验不符回退编号解析）防串句；
   单句直接译文（流式友好）+ stripSingleLineNoise 净化
5. **VAD 增强**：Pipeline/VAD/VAD.swift——isNonSpeech = RMS<阈值 || ZCR>0.35
   （高频嘶声/电流噪判静音；人声/音乐低 ZCR 不误伤）；接入 lastSilenceCut
   与 hasTrailingSilence；5 个 VAD 单测（静音/人声/高频噪/音乐/边界）
6. **下载完整性校验**：落盘前实际字节 vs 期望（folder 精确 size / Content-Length），
   差异>1% 判损坏报错重试，不再把半截文件标记完成
7. **ASR 自动降级**：连续 5 次 chunk 失败（CancellationError 不计）且未降级过
   → 自动切 Apple 引擎 + toast；每会话只降一次防风暴
8. **翻译基准测试**：设置页「基准测试」——3 句固定样本（短中/中英/长中文）
   走当前配置流式路径，输出总耗时/均值/译文预览
9. **字幕主题预设**：CaptionSettings 顶部 5 套（观影/会议/极简/大字/高对比）
   一键应用字号/背景/边框/字重，应用后可微调
10. **菜单栏快捷控制**：MenuBarController（NSStatusItem）——显示主窗/
    开始结束录制/引擎三选/浮层穿透切换/退出；AppDelegate applicationDidFinishLaunching 接线
11. **上下文轮数可配**：translationContextRounds（默认 2，0–8 stepper），
    批量/实时翻译上下文句数
12. **i18n 框架**：App/L10n.swift 代码字典表（key→zh/en，系统语言判定，
    未登记 key 原样返回渐进接入）；菜单栏 + 返回按钮已双语落地

### 验证状态

- 单测 56/56 全绿（新增 VAD 5 + 翻译解析 11：JSON 数组/围栏/句数校验/
  编号回退/思考分离/单句净化）
- debug / release / 打包通过，应用已重启（14966）

### 真机回归清单（新增项）

1. 流式翻译：在线/本地翻译模式下说话——译文应逐字增长（不等整句）
2. 思考模型：接 DeepSeek-R1/GLM/Qwen3 翻译不再返回空
3. 国内镜像：下载源切镜像后模型可下载
4. 噪声场景：有风扇/电流噪的环境断句是否改善
5. 菜单栏：状态栏图标 → 各菜单项；字幕主题一键切换
6. ASR 降级：故意断网/错误配置观察 5 次失败后自动切 Apple

### 新坑 25：大改造用「锚点脚本 + 每步构建」逐环节推进

12 项功能 + 结构重组一次会话完成的可行做法：
- python 锚点替换（assert count==1 保证唯一），每步 swift build 验证；
- 锚点失败时先查实际文本差异（本轮三次翻车均为注释措辞/属性归属不同）；
- 多 view 共存的设置页加 UI 时，确认方法插入到正确的 struct
  （testConnection 属 RecognitionSettingsView，benchmark 曾插错）；
- SwiftPM 同 target 内 git mv 目录重组零编译影响，放心做。

### 17.5 追加补丁：日韩语支持（评估后落地两个小项）

上节评估 LiveTranslate 的 jaconv/jamo/yasbd 时结论「先不调整」，但其中
两个小补丁无依赖、即有价值，已落地：

1. **翻译输入 NFKC 归一化**：`TranslationService.normalizeForTranslation`
   （precomposedStringWithCompatibilityMapping + trim）在
   translateSegmentsWithOpenAI 输入收口 + AppleTranslationEngine 入口——
   ASR 偶发全半角混排（全角数字/英数/标点）归一为标准形再送翻译，
   提升 LLM 稳定性；**显示层不动**（字幕保持识别原样）。
2. **韩文语言分支**：SubtitleLanguage 加 .korean（Hangul 检测 AC00-D7A3
   /Jamo/兼容 Jamo，优先级 Cyrillic→Hangul→CJK）；断行宽度 32 字/行
   （介于中文 26 与西文 44），断点复用西文（空格/逗号，韩文有空格分词）；
   长度兜底断句加韩文档位 40 字符。

测试 56→67（新增 11：韩文检测/边界/宽度/词边界断行/长度档位 +
归一化全角数字/标点/CJK 保持/trim）。

### 17.6 追加：移植 yasbd 17 语言母语分句规则（SentenceRules）

新文件 `Pipeline/Subtitle/SentenceRules.swift`：

- **脚本路由**：SentenceScript.detect 按 Unicode 区段（低频脚本优先扫描）
  → 12 类脚本 → 各自句末标点规则：
  CJK 。？！.；韩/拉丁/西里尔 .?!（句点带小数+缩写保护）；希腊 ;=?!
  （「;」是希腊问号）；阿拉伯 ؟۔.?!；天城文 ।॥；亚美尼亚 ։；
  埃塞文 ።፧；**泰/老挝/缅甸无句末标点**（terminators 空集——母语实况，
  回退 VAD+长度兜底）；mixed 保守全集。
- **流式误判保护**（yasbd 批量规则的流式等价）：
  1. 小数保护：「3.」末字符句点 + 前字符数字 = 流式未决，不立即断
     （下一轮「3.14」自然非终止；纯数字结尾漏断由 VAD 兜底）；
  2. 缩写保护：句点前词在多语言缩写集（Mr/Dr/e.g/т.е… 30+）不判句末。
- **Detector 接入**：config.sentenceTerminators 改 Optional（nil=按脚本
  自动；显式赋值覆盖供测试/定制）。

**测试翻出 1 个真 bug**：中英混排文本判为 CJK 脚本后西文句点不在
终止表 → 混排英文句断句失效（极常见场景）。修复：CJK 规则纳入西文
句点（带小数/缩写保护，中文句号无歧义不受影响）。

测试 67→89（+22：11 语言终止符/小数两轮流式/缩写延迟成句/泰语无标点
回退+长度兜底/12 脚本检测/自定义覆盖/混排句点）。

### 17.7 追加：流式引擎语义协议化（坑 14/17 的类型化收口）

评估「五级流水线关注点分离」时指出的隐性债务，现已落地：

- **ASRProvider.isStreamingEngine**（默认 false）：流式引擎声明式标记。
  坑 14/17 从文档约定升级为类型系统——新流式引擎只需声明标记，
  **零水位线代码**。
- **StreamingFeedWaterline**（ASRProvider.swift，纯类型可单测）：
  绝对采样坐标去重水位线。**上提到 TranscriptionService（调度层）**——
  调度层才知道「tail 重转录」的调用方语义，provider 不该知道：
  - 非聚合路径：流式引擎按 absoluteRange 裁出纯新增再 dispatch；
    全部已喂返回空结果；无区间保守全量喂+清水位线；
  - 生命周期：unloadLiveModel 清零；实时引擎切换清零
    （streamingWaterlineEngine 记录上次流式引擎，切换即 reset）；
  - 聚合（ChunkManager）路径不经水位线（本地引擎恒无状态）。
- **AppleSpeechManager 瘦身**：删除 liveFedAbsoluteSamples/unfedSamples
  及 prepare/unloadModel/cancelPending/懒启动四处重置——只声明
  isStreamingEngine=true，transcribeChunk 收到的即纯新增。

测试 89→97（+8 水位线：首喂/重叠尾/全重不喂不推进/静音跳过续喂/
强制封口上下文不重发/无区间保守回退/reset/区间回缩单调性）。

### 17.8 追加：二轮对标（重读 releases）四项落地

重读 LiveTranslate releases 后新发现的四点，落地三项 + 分段启动一项：

**小项 1：思考模式手动厂商组**（ThinkingControl 六档）
auto / DeepSeek·火山方舟·GLM（thinking.type=disabled）/ Qwen·百炼·硅基流动
（顶层 enable_thinking=false）/ vLLM·SGLang（chat_template_kwargs）/
OpenAI·Grok（reasoning_effort=none）/ 不发送。auto 按模型名识别组别，
识别不出不发送；手动组 = 自部署/改名模型的兜底。旧值 off 并入 auto。

**小项 2：翻译提示词预设**（TranslationPromptPreset 五套）
默认（清空）/ 会议口语 / 影视字幕（长度约束）/ 技术文档（术语保留）/
身份核验（标识符原样保留，参考其 WebID 预设）。点选填入文本框仍可改。

**小项 3：应用内日志查看器**（系统状态页「最近日志」区）
分类 segmented 过滤 + monospaced 只读 40 条 + 刷新按钮
（AppLogger 环形缓冲 1000 条复用）。排障不再手动挖 app.log。

**ASR 子进程隔离——段 1（进程内看门狗）**
新文件 Pipeline/ASR/ASRWatchdog.swift：
- ProcessMemory.footprintBytes（task_info phys_footprint，活动监视器口径）
- MemoryReclaimPolicy 纯策略（默认上限 6GB，可配 asrMemoryCeilingMB；
  60s 冷却；超限 && 全空闲 才回收）
- 挂接 ASRManager 5s 健康检查：空闲超限 → service.shutdown() 释放全部
  模型 + toast（下次使用懒加载回来，用户无感）
- 挂接 TimeoutError 路径：连续 2 次推理超时 → unloadLiveModel
  （下轮 pass 懒加载重建——进程内回收死锁/损坏的推理上下文）
- 段 2（未做，真·隔离）：XPC Service 子进程跑推理引擎，崩溃自动重启。
  需要 Package.swift 新 target + 打包脚本嵌入 XPC + entitlements，
  待段 1 真机验证收益后再决定是否值得。

测试 97→106（+9 回收策略边界 + footprint 采样冒烟）。

### 17.9 追加：性能小专项（启动 XPC / 日志开销）

三项查证后落地的性能治理（全部构建实测）：

**A. 启动路径去 N+1**：AppRuntimeManager.attach（App 启动即调）→
AppleTranslationStatus.refresh 原本查 installedLanguageCount——
supportedLanguages(~40+) × 2 候选源 = ~80 次串行 LanguageAvailability
XPC，而该数据只有 Apple 服务设置页展示。拆分：refresh() 不再查 count，
新增 refreshInstalledCount() 由设置页 onAppear 按需调。启动零额外 XPC。

**B. Renderer 高频日志摘要化**：pushState 每次 print 30 段完整
debugDescription 数组（0.15s 节流一次 + 每次状态变化，实时识别期每秒
构造数 KB 转义字符串）。release 改为 AppLogger 摘要（count + 末段 24
字符）；DEBUG 构建保留全量（排障需要）。updateSubtitleState /
Subtitle Display render 同步改 AppLogger + 截断。

**C. AppLogger 异步批量 stdout**：log() 原本逐条 print 到无缓冲重定向
文件 = 每条一次 write syscall（实时期每秒 10-30 次）。改：ring buffer
同步写（recentLogs 立即可读），stdout 走 pendingStdout 批量队列，
0.3s 合并一次写出；applicationWillTerminate flushNow() 防丢尾。

验证：106/106 测试全绿；release 打包重启通过，启动日志正常
（异步 flush 后 app.log 仍完整写入，最大滞后 0.3s）。

### 17.10 追加：bug 检查 + 死代码清理 + 文件夹整理

**修出 2 个真 bug**：
1. **AppLogger DateFormatter 数据竞争**：dateFormatter.string() 在锁外
   调用（原实现就有，非上轮引入）——ASR 后台/翻译/UI 线程并发 log 时
   DateFormatter 非线程安全，可能崩溃/乱码。格式化移入锁内。
2. **MenuBar 菜单状态不刷新**：menuWillOpen 从未设 menu.delegate——
   状态栏菜单显示的录制状态/穿透可用性是构建时快照。接线
   NSMenuDelegate（每次打开前 rebuild）。

**死代码清理**：SubtitleSplitter.split(text:) 单参版（零引用）、
AppleSpeechManager.prefersOnDevice（零引用；UI 直接读配置）。

**文件夹整理**：根目录游离文档归位 docs/（newdme.md、
smartsteer-status.md，git mv 保留历史）。根目录终态：包定义
（Package.swift/.resolved）+ README×2 + LICENSE + CLAUDE.md +
Assets/Frameworks/Scripts/Sources/Tests/docs + 构建产物 WhisperASR.app +
交接文档 HANDOFFtmd/（工作未提交期间保留显眼位置，提交后可归档）。

验证：106/106 全绿，release 打包重启通过。

### 17.11 追加：菜单栏与主窗口双向同步 + 语言快捷切换

用户报告「菜单栏状态与主窗口不同步」。根因：菜单栏 selectEngine 直接写
UserDefaults 绕过 @Observable 配置层——设置页 Picker 绑定的是
ConfigurationManager 属性，菜单栏改动后 UI 收不到通知（反向方向靠
menuWillOpen rebuild 已覆盖）。

修复 + 扩展（MenuBarController）：
1. **selectEngine 改走配置对象**：`ConfigurationManager.shared.asr
   .asrEngine = engine`——didSet 持久化 + Observable 通知，设置页/主窗口
   实时同步；不再直接写 UserDefaults。
2. **新增「识别语言」子菜单**：按 TranscriptionService.languageSupport
   分支——可手动指定的引擎列出 whisper 全语言表（前 30 + 自动检测，
   当前项 ✓）；Qwen 显示自动检测说明；Apple 显示语言包说明。写
   `asr.asrLanguage`（同走配置层）。
3. **新增「翻译语言」子菜单**：TargetLanguage.available 全列表，
   写 `translation.targetLanguage`（didSet 持久化 + 通知；实时翻译/
   文件翻译/批量翻译三链路都读该键）。

同步闭环验证路径：设置页绑定 `$recognition.asrLanguage` /
`$translation.targetLanguage`（@Observable 直绑），菜单栏写同一对象 →
UI 刷新；反向设置页改值 → 菜单打开时 menuWillOpen rebuild 显示 ✓。

测试 106/106 全绿；release 打包重启通过。

### 17.12 追加：修「菜单栏消失」（AppKit 打开中替换菜单陷阱）

17.11 引入的回归：menuWillOpen（菜单正在打开/显示）里 rebuildMenu →
`statusItem.menu = 新实例`——AppKit 在打开遍历过程中销毁正在显示的
status item 菜单是未定义行为，实测状态项图标整个消失。

修复（MenuBarController 重构为固定条目 + 原地刷新）：
- 菜单结构一次构建，recordItem / passthroughItem / engineItems /
  asrLanguageItems / targetLanguageItems 存条目引用；
- menuWillOpen 只调 refreshDynamicState()：原地改录制标题、穿透
  enabled、三组子菜单的 ✓ 标记——永不替换正在显示的菜单实例；
- 选择动作回调里的 rebuildMenu 全部移除（✓ 由下次 menuWillOpen 刷新；
  正在显示的子菜单不能动）。

测试 106/106；release 打包重启通过。真机验证：点状态栏图标弹菜单
（图标不消失）、切引擎/语言后 ✓ 正确移动、录制状态实时反映。

### 17.13 追加：日志复盘修降级链 + 菜单语言按服务显示

用户报「字母刷新有问题」，日志还原出完整事故链（真机实测数据）：
在线引擎失败 ×5 → 17:59:37 自动降级切 Apple → **Apple 语音识别权限
「未请求」** → 立即抛未授权错误 → 每 0.5s 失败循环刷屏、字幕卡死旧句、
tail 涨到 30s 上限。暴露降级链两个 bug：

1. **降级不验证目标引擎可用性**——切到未授权引擎等于没救；
2. **hasAutoDegraded 挡住二次干预**——死循环无提示。

修复：降级前先 `AppleSpeechManager.prepare()` 探测（授权+语言资源），
**成功才切换**；探测失败保持原引擎 + toast 指引用户修复。

菜单栏语言按服务显示（与主窗口设置页同数据源/同语义）：
- 识别语言：languageSupport 分支——可指定引擎=自动检测+whisper 语言表；
  Qwen=自动检测说明；Apple=语言包说明（原实现已按此分支，本轮确认并
  补 asrLanguageItems 引用重建）。
- 翻译语言：按 TranslationMode.current 过滤——off=禁用说明；apple=
  系统翻译支持集（zh-Hans/zh-Hant/en/ja/ko）；localModel=常用三语
  （en/zh-Hans/ja）；onlineAPI=全列表。
- 移除「显示主窗口」项（无用；动作方法与 L10n key 一并清理）。

测试 106/106；release 打包重启通过。真机验证：在线断网录制 → 5 次
失败后 toast 指引（不再死循环刷屏）；菜单栏语言子菜单随服务变化。

### 17.14 追加：「显示主窗口」是失效不是没用——恢复并修复

17.13 误判用户语义（「显示主窗口没用」= 点击无效果），已删除。
实为 bug：原实现 `NSApp.windows.first(where: canBecomeMain)` 在多窗口
（主窗 + 字幕浮层 + 选择弹窗 + 设置窗）下可能选中浮层/弹窗；且应用
未激活时仅 makeKeyAndOrderFront 不带 activate 不前置。

恢复菜单项并修复动作：精确过滤（canBecomeMain && visible && 非 NSPanel
&& 宽度 >400 排除紧凑浮层）+ `NSApp.activate(ignoringOtherApps:)` 前置。

测试 106/106；release 打包重启通过。

### 17.15 追加：修「菜单栏依旧不显示」——setup 时序竞争（真根因）

17.12/17.13 修的 menuWillOpen 替换菜单不是图标消失的根因。真根因：
MenuBarController.setup 挂在 applicationDidFinishLaunching，而
appState/audioRecorder 由 ContentView.onAppear 注入——**启动时序上
onAppear 晚于 didFinishLaunching**，setup 被调时 AppDelegate 属性还是
nil：状态项创建依赖空引用，状态栏图标不出现。

修复：接线移到注入点之后（onAppear 内 appDelegate 属性赋值后立即
MenuBarController.shared.setup(appState:audioRecorder:)），
applicationDidFinishLaunching 的 setup 调用删除。

测试 106/106；release 打包重启通过。验证：状态栏 waveform 图标出现、
菜单可弹、各动作可用。

### 新坑 26：SwiftUI App 的 AppDelegate 注入时序

@NSApplicationDelegateAdaptor 的 AppDelegate 属性由 View.onAppear 注入
时，applicationDidFinishLaunching 里它们还是 nil——任何依赖注入对象
的初始化必须挂在注入点之后（onAppear 内），不能挂应用级生命周期回调。

### 17.16 追加：菜单识别语言两处修正（引擎同步 + Apple 可选语言）

用户指出两个问题：
1. **切到在线后识别语言子菜单不同步**（还显示 Apple 的说明）——
   子菜单在 setup 时构建一次，实例固定，refreshDynamicState 只刷 ✓
   不重建结构。修复：makeLanguageSubmenu 按 ASREngineSelection.current
   分支构建（apple→语言包子菜单 / qwen→说明 / 其他→whisper 表）；
   selectEngine 动作后 rebuildMenu()（菜单已随选择关闭，替换安全；
   新增 isMenuOpen 守卫 + menuDidClose 追踪，打开中禁止替换——17.12
   的陷阱不复发）。
2. **Apple 识别其实支持选语言**（此前显示"由语言包决定"是做错了）——
   appleLocaleSubmenu 直接列出已安装语言包（AppleLanguageManager，
   写 appleSpeechLocale，与设置页「当前语言」同一配置键）；
   AppleSpeechManager 新增 installedLocaleIdentifiers() 同步包装。

测试 106/106；release 打包重启通过。验证：菜单切在线 → 重开菜单识别
语言变 whisper 表；切 Apple → 变已安装语言包列表且可选。

### 一句话总结（第 17 节）

对标 LiveTranslate 的 12 项全部落地（流式翻译/思考兼容/双下载源/JSON 批量/
VAD 增强/下载校验/自动降级/基准测试/主题/菜单栏/上下文轮数/i18n）+ 源码
按管线六环节重组；56 测试全绿、构建打包重启全通过；待真机回归六项。

---

## 18. 第十轮会话（2026-08-22 10:00–）：FunASR Provider 接入（按规格分步实施）

### 架构决策与约束（实施前已对齐）

1. **FunASR 无官方 Swift 绑定**：可行路径 = sherpa-onnx Swift API
   （FunASR 官方 ONNX 模型在其生态推理）。**段 1 用占位 Runtime**
   （明确报错不静默失败），Provider/路由/目录/UI 全链路先通。
2. 规格中的 `AudioChunk`/`ASRModelType`/`ASRRuntime` 是目标态签名——
   按现有真实类型等价落地（`[Float]` PCM / `TranscriptionResult` /
   `ModelEngine.funasr`），不引入平行类型体系。
3. 目录：现有 `Pipeline/ASR/FunASR/`（非规格的 Speech/Providers——
   与既有组织一致，避免无谓搬迁）。

### 已完成（3 个 commit）

1. `feat: add FunASR provider architecture`
   - `Pipeline/ASR/FunASR/FunASRRuntime.swift`：FunASRModelType 四枚举 +
     FunASRRuntime 协议 + Placeholder 运行时；
   - `FunASRProvider.swift`：完整 ASRProvider 实现（prepare/loadModel/
     transcribeChunk/transcribeFile/status；isStreamingEngine 跟随模型类型，
     paraformer-streaming=true 走调度层水位线）；
   - `ASREngineSelection/.funasr` + `ResolvedEngine/.funasr` + 全部分发
     （chunk/file/preload/waterline/languageSupport/debug 描述，共 9 处 switch）；
   - 设置页三项选择器归「本地模型」范畴（配置区互斥逻辑复用）。
2. `feat: add FunASR model catalog (SenseVoice/Paraformer/Nano) + settings grouping`
   - ModelCatalog 四模型（hfFolder 源）：sensevoice-small(~900MB) /
     paraformer-zh-streaming(~250MB) / paraformer-zh(~850MB) /
     fun-asr-nano(int8 ~760MB)；isComplete 单文件判定；
   - engine(forPath:) 按 catalog 元数据自动判定 funasr 引擎；
   - 设置页模型列表分组显示（FunASR 组 / Whisper·Qwen·Nemotron 组）。
3. 存量先行提交：此前 91 个未提交文件按逻辑分两个 commit
   （refactor 管线架构 + chore 交接文档），FunASR 变更不再混杂。

### 未完成 / 下一步

1. **sherpa-onnx 后端**（段 2 核心）：Package.swift 加依赖（或预编译
   xcframework 入 Frameworks/）、实现 FunASRRuntime 的 load/infer/unload、
   SenseVoice tokens 解析（CTC greedy → 文本 + 时间戳）。
2. **FSMN-VAD / CT-Punc 辅助模块**（规格第七节，可选）：FSMN 替换 RMS+ZCR
   （现有 Pipeline/VAD 接口不变）；CT-Punc 只作用于文件转录结果文本。
3. **真机验证**：模型下载（hfFolder 多文件 → 单 onnx 落盘路径需确认
   resolveModelPath 语义匹配）、runtime 报错文案。

### 18.1 追加：FunASR 段 1 审查——修 4 个真 bug + 后端接入点准备

审查发现并修复（commit `fix: FunASR provider hardening...`）：
1. **modelType 恒为默认值**（严重）：catalog 选 paraformer-zh 也不切换，
   isStreamingEngine 判断失真——改为按模型路径从 catalog 推导；
2. **load 非原子**：实时循环与文件转录并发双加载——in-flight task
   去重（同路径等待复用；路径变化先卸载）；
3. **目录语义错误**：单 .onnx 文件路径被标 isDirectory:true——
   load(modelPath:modelType:) 明确文件语义，tokens 附属文件同目录由
   后端解析；
4. **菜单栏引擎 ✓ 漏 funasr**。

为段 2（sherpa-onnx）准备的接入点：
- **FunASRRuntimeRegistry**：后端实现 FunASRRuntime 后一行
   `register()` 全链路生效（Provider 经 Registry 取运行时，占位/真实
   对 Provider 透明）；协议简化：infer(pcm:)（模型类型 load 时已知）；
- **ASRModelType** 统一枚举（规格第三节）：whisper×3 / qwen3ASR /
   nemotron / senseVoiceSmall / paraformerStreaming / paraformerZH /
   funASRNano → engine 映射；设置页 FunASR 分组排序可用
   isRealtimeRecommended。

死代码清理：空 extension、悬空注释、infer 冗余参数。
测试 106/106；release 打包重启通过。

### 19.5 追加：Phase 2/3 全模型接入（2 commit）+ 引擎误路由修复

**fix commit**（用户报错触发）：SenseVoice 目录被 engine(forPath:) 的
「目录→一律 Nemotron」分支误路由 → 报 metadata.json not found。
修复：目录分支先查 catalog（fileName 命中 engine==.funasr → .funasr）。

**Phase 2**（`feat: add Paraformer-zh-streaming runtime`）：
- OnlineRecognizer + **持久 stream**（会话状态跨 transcribe 保留）；
- 端点检测（尾静音 1.2s / 20s 上限）→ SherpaOnnxOnlineStreamReset 开新段
  （注意：函数名是 OnlineStreamReset，非网上资料的 ResetOnlineStream）；
- 累积文本 → 增量：公共前缀 diff（与 Apple waitForTextGrowth 同语义）；
- 流式冒烟 PASS（Scripts/funasr-stream-smoke.swift）：创建/跨轮状态/
  endpoint/reset/释放全链路（hf-mirror 下载 226MB 模型实测）。

**Phase 3**（`feat: add Paraformer-zh + Fun-ASR-Nano offline configs`）：
- paraformerZH：Offline paraformer 配置（时间戳透传，文件转录场景）；
- funASRNano：FunASRNanoModelConfig（encoder-adaptor/llm/embedding/
  tokenizer 四文件；官方 repo csukuangfj/sherpa-onnx-funasr-nano-2512-int8）；
- catalog 四模型全部目录语义（官方转换 repo）；
- FunASRModelConfig：目录名精确匹配 + 自定义目录文件特征探测双路；
- Provider 类型推导统一走 FunASRModelConfig（删重复映射）。

**新坑 28**：sherpa-onnx 新版 API 命名细节——Reset 是
SherpaOnnxOnlineStreamReset（词序与旧资料不同）；provider 等 C 字段
必须 strdup（字面量赋值报 String→UnsafePointer）；方法名 cString 与
String 扩展冲突（改名 dup）；free 全局重载歧义用 deallocate。

待真机：SenseVoice/paraformer-streaming 实时字幕；paraformer-zh 文件
转录（时间戳）；Nano 模型下载验证（~900MB）。

### 一句话总结（第 18 节）

FunASR 以 Provider 形态接入既有管线（非独立系统）：四模型目录/路由/UI/
流式语义声明全通，runtime 占位报错；存量工作区先行清理提交。下一步
sherpa-onnx 后端实现。

---

## 19. 第十一轮会话（2026-08-23 01:40–02:00）：sherpa-onnx 后端全链路接入（4 commit）

按确认决策（B 方案自建 xcframework + 官方 C API）完成规格四 commit：

### Commit `feat: add FunASR runtime backend interface`
接口对齐规格签名（isAvailable / load(modelURL:) / transcribe(pcm:sampleRate:) /
unload）；FunASRModelConfig（模型文件清单+完整性）；SherpaONNXRuntime 骨架。

### Commit `feat: add sherpa onnx bridge`
- **xcframework 构建**（本地 /tmp/sherpa-build，过程可复现）：
  官方 release `v1.13.6 osx-arm64-static-no-tts-lib`（18MB 包，12 个 .a
  自包含 onnxruntime）→ libtool 合并 82MB libSherpaONNX.a →
  xcodebuild -create-xcframework + headers（c-api.h 经 jsdelivr CDN 取
  v1.13.6 tag，167KB）+ module.modulemap（module SherpaONNX）；
- Package.swift binaryTarget + 启动注册（WhisperASRApp onAppear 内，
  `FunASRRuntimeRegistry.register(SherpaONNXRuntime())`）；
- 启动日志验证 "SherpaONNX runtime available"，app 无符号缺失。

### Commit `feat: integrate FunASR inference runtime (SenseVoice, Phase 1)`
- **重要发现**：v1.13.6 的 c-api.h 是**新版驼峰 API**
  （SherpaOnnxCreateOfflineRecognizer / AcceptWaveformOffline /
  DecodeOfflineStream / GetOfflineStreamResult），与旧 snake_case 完全
  不同——按新版重写桥接；
- SherpaONNXRuntime 完整实现：SenseVoice 配置（model.int8.onnx +
  tokens.txt + use_itn + 2 线程 cpu）、strdup C 字符串生命周期管理、
  NSLock 串行化、时间戳透传；错误语义按规格第八节（runtime
  unavailable / model load failed / inference failed，不静默不自动换）；
- create 返回非 Optional（新版约定）——文件预检兜底路径错误。

### Commit `test: verify FunASR realtime transcription runtime`
- 模型就位：hf-mirror 下载 SenseVoice int8（228MB + tokens 308KB）至
  catalog 目录（HF 直连不通，镜像可用——下载源设置已支持）；
- **独立冒烟 PASS**：sherpa-onnx 1.13.6 / onnxruntime 1.27.1，
  recognizer 创建 ✓ 推理路径 ✓（440Hz 正弦→"I." 合理）释放 ✓；
- `Scripts/funasr-smoke.sh` 可复用冒烟工具；
- catalog 修正：SenseVoice 源从 FunAudioLLM 原始仓（fp32）改为官方
  int8 转换版 csukuangfj/sherpa-onnx-sense-voice-...（目录语义，
  isComplete 检 model.int8.onnx）。

### 踩坑记录（新坑 27）

1. **heredoc 写 Swift 的 `\\(` 陷阱**：cat <<'SWIFT' 内容里插值写了
   双反斜杠导致解析错位（报成 extra argument / T 推断失败等假错误）——
   heredoc 后必须 grep 检查 `\\(`；
2. **新版 C API 是驼峰**：网上资料多为旧 snake_case（sherpa_onnx_...），
   以 xcframework 内 c-api.h 实际为准；
3. **静态库冒烟需 -lc++**；**xcframework 生成需 DEVELOPER_DIR=/Applications/Xcode.app**
   （xcodebuild 在 CommandLineTools 下不可用）；
4. **raw.githubusercontent 直连失败**，jsdelivr CDN（cdn.jsdelivr.net/gh/
   repo@tag/path）可用。

### 待用户真机验证（Commit 4 测试 2/3）

1. 实时：设置选 SenseVoice → 录制 → 字幕浮层出字（链路：AudioRecorder
   → ASRManager chunk → 水位线（SenseVoice 声明无状态，不裁剪）→
   FunASRProvider → SherpaONNXRuntime → SubtitleManager）；
2. 文件：拖入中文音频 → 历史 items 出 SenseVoice 转录。

### 下一步（Phase 2/3）

- Paraformer-zh-streaming（OnlineRecognizer 流式接口 + isStreaming
  语义已有水位线支持）；Paraformer-zh（时间戳）；Fun-ASR-Nano
  （LLM 配置结构 c-api.h 已含 FunASRNanoModelConfig）。

---

## 20. 第十二轮会话（2026-08-23 03:30–04:30）：引擎分类「你做了吗」事故全记录

### 事故主线（用户质疑完全正确）

1. **真 bug**：engine-classified commit 的批量 python 脚本在 catalog 区
   锚点失配后 assert 中断——**本地模型分组写入了、引擎筛选 Picker
   从未落盘**，构建通过让我误报"完成"。用户截图揭穿。
2. **补写后进入幽灵 bug 弯路**：筛选 Picker 字符串在 debug 二进制在、
   release 不在（UTF-8 子串搜索判定）。经历：增量怀疑→双产物目录
   （.build/release 与 .build/arm64-apple-macosx/release 并存）→
   全清 .build（代价：FluidAudio 缓存丢失，已 bare-clone 恢复到
   ~/Library/Caches/org.swift.swiftpm/repositories/FluidAudio-19600a48，
   GitHub 直连时断时续需重试）→措辞/marker 实验→Text(verbatim:)「修复」。
3. **最终反转（铁证）**：全项目扫描 105 个纯中文 Text 字面量，40 个
   判"missing"——其中包括「下载源」「官方直连」等**用户截图里正常
   显示过的文字**。结论：**UTF-8 子串搜索检测 Swift 字符串在二进制
   的存在性不可靠**（误报率 ~38%；Swift 字符串在 Mach-O 存在非 UTF-8
   连续的存储形式）。之前的"消失"全程是检测方法盲区，UI 大概率
   一直正常。Text(verbatim:) 改动语义等价、无害保留。

### 新坑 29：UTF-8 字节搜索 ≠ 字符串入二进制的判据

`'文本'.encode() in open(binary,'rb').read()` 对 Swift 字面量误报率
极高（本例 40/105）。判定 UI 功能是否打包：以 debug 构建 + 源码
grep + 用户 UI 确认为准；二进制字节验证只可作正向佐证（在=一定在，
不在=不确定）。

### 新坑 30：python 锚点脚本的静默半失败

多段 replace 脚本中途 assert 失败时，前面已 replace 的段**不会写盘**
（open 在最后）——但若脚本结构是"逐段写入"或分两个脚本，则产生
**部分写入**：构建通过、功能却缺一半。纪律：每个功能点完成后必须
`grep -c 关键符号 源文件` 逐项验证，再报告完成。

### 当前待确认（用户一眼即可）

设置 → 识别 → 语音识别模型区顶部「按引擎筛选」Picker（全部/
Whisper/Qwen3/Nemotron/FunASR）+ 分组列表是否显示。代码在源码
（grep engineFilter ✓）、debug 功能验证 ✓、release 结构串在 ✓
——只差 UI 目视确认。若真不显示（小概率），备选修复已验证过
Text(verbatim:) 路径（commit 已含）。

### 本轮 commits

- fix: catalog engine filter picker actually written（补落盘）
- fix: engine filter label wording（弯路产物）
- fix: Text(verbatim:) for engine filter label（无害保留）

---

## 21. 第十三轮会话（2026-08-23 04:50–05:10）：深度架构报告对标第一二四节落地

依据用户保存的 LiveTranslate 深度技术架构报告（实现层细节，比 releases
对标多出的部分），按用户指定优先级（四 → 一 → 二）7 项全部落地，
3 个 commit、测试 106→118：

**Commit A `a993a54`（第四节·可靠性）**
- #10 看门狗基线相对制：MemoryReclaimPolicy 加 baselineBytes（preload
  成功点 recordBaseline 快照），生效上限 = min(基线+2GB, 绝对上限)，
  显式配置绝对制优先——泄漏检测适配模型大小而非固定 6GB 猜测；
- #9 降级代数守卫：auto-degrade 的异步 prepare 前快照引擎选择，
  完成后校验未变才写入——用户探测期间手动换引擎不再被迟到降级覆盖。

**Commit B `51277c4`（第一节·VAD 断句体系）**
- #1 自适应停顿：最近 50 次真实停顿（干净封口时记录）P75×1.2 夹
  [0.3, 2.0]s 作为停顿判定时长（纯函数可测）；
- #2 渐进式静音：tail >6s 停顿需求减半、>10s 四分之一；
- #3 谷值回溯：8s 强制封口改为后 70% 区间 5 帧平滑能量最低点，
  谷值 < 段均值 80% 才有效（自然停顿切分），无谷值才硬切；
- #4 密度门：tail >1s 且语音帧密度 <25% 直接按静音封口跳过 ASR
  （音乐底噪/碎音段不浪费推理）；AudioRecorder 新增 speechDensity
  与 lowestEnergyCut 扫描（与主循环同源 VAD 判定）。

**Commit C `0c32fb0`（第二节·补零桶化）**
- InputBucketing（0.5s 量子=8000 样本）：whisper/qwen/SenseVoice 的
  chunk 输入补零对齐——限制输入形状集合，避免 GPU kernel 重选/
  显存池扩张的周期性延迟毛刺（平均多算 ~0.25s 尾部静音，成本极小）；
  流式 paraformer 排除（补零破坏流语义）、文件转录一次性无需。

**下轮待做**（第三节翻译层 + 第五节显示层）：
#5 三铁律提示词（ASR 容错下沉 LLM）、#6 上下文双路径、#7 复读机检测、
#8 空 completion 诊断、#11 字幕最短停留、#12 分区动态穿透、#13 OBS 窗。

---

## 22. 第十四轮会话（2026-08-23 05:20–05:40）：深度报告第三/五节 + 补零可配置

按用户指定范围（三、五、补零可调）全部落地，3 commit、测试 118→123：

**Commit `13c2214`（第三节·翻译层）**
- #5 三铁律：所有提示词（默认+自定义）统一追加——单条最佳译文/
  专名不译/**依据上下文静默纠正 ASR 错误**（容错下沉 LLM）；
- #6 上下文双路径：自定义模板含 {context} → 历史嵌 system；否则
  历史转 user/assistant 交替多轮消息（token 效率更高）；
- #7 复读机检测：≥3 次重复 8 字片段且覆盖 ≥30% 输出 → 明确失败
  （循环输出防护；覆盖率阈值防正常文本误报，测试锁定）；
- #8 空 completion 诊断：tokens>0 但译文空 → 日志+错误明示
  "思考耗尽输出预算"（指路调整思考模式/max_tokens）。

**Commit `d9982cc`（第五节·显示层）**
- #11 句子最短停留 1.5s：过快的新句排队延迟顶替（后到者胜），
  同句打字增长不受限（防字幕跳变闪读）；
- #12 穿透快速呼出：光标进入浮窗底部 44pt 功能区条带立即显示控制栏
  （想操作的人无需等 3 秒停留）；字幕主体维持原停留判定；
- #13 OBS 纯净字幕窗：无边框透明第二显示端（白字黑边描边、原文大字+
  译文小字、allowsHitTesting(false) 纯显示），共享 FloatingLetter
  renderer 状态双窗同步；菜单栏「OBS 字幕窗」开关带 ✓。

**Commit `81efb93`（补零量子可配置）**
asrPadSeconds：0.25 / 0.5(默认) / 1s Picker + 禁用（0 = 原始长度）。
InputBucketing.quantumSamples 动态读取；设置页音频处理区。

### 验证

123/123 全绿（新增 5：复读机检测×3 含覆盖率阈值/桶化禁用/自定义量子）；
release 打包重启通过。

### 待真机验证

1. 翻译：接 DeepSeek-R1 观察空回复诊断日志；长句不再循环刷屏；
2. 显示：快语速下字幕最短停留是否改善闪读；穿透模式鼠标移底部即呼出；
   OBS 窗采集画面白字黑边清晰；
3. 补零桶化：禁用 vs 0.5s 对比长时间录制的延迟稳定性。

### 下轮候选

- FSMN-VAD（sherpa-onnx 内置 VAD 替换 RMS+ZCR——c-api.h 已见
  Silero/Ten VAD 结构，模型 ~2MB）；
- CT-Punc 标点恢复（offline punctuator，仅文件转录文本后处理）；
- 远程 ASR Provider（对标 Remote Whisper，HTTP 二进制协议）。

### 一句话总结（第 18 节）

---

## 23. 第十五轮会话（2026-08-23 05:50–06:00）：OBS 原生鼠标输入 + 终扫

### OBS 字幕窗原生鼠标输入（用户点名）

- 面板 borderless → **titled + resizable + fullSizeContentView +
  透明标题栏**（与主浮层同方案）：原生边缘/四角缩放 + 系统光标，观感
  不变；minSize 360×90；
- **背景拖拽**：自定义 ObsSubtitleHostingView（private，NSView 层）
  mouseDown → performDrag——SwiftUI 层 allowsHitTesting(false) 只挡
  文字命中，不阻断 NSView 拖拽转发；
- 菜单栏「OBS 字幕窗」开关带 ✓ 状态刷新。

### bug 终扫结果

- 主浮层穿透模式 styleMask remove(.resizable) 后恢复路径确认正确
  （interactive 分支重新 insert）——无问题；
- 运行日志无新错误；123/123 测试全绿；release 打包重启通过。

### 死代码清理

L10n 未用 key ×4（menubar.asrLanguage.apple / common.settings /
common.cancel / common.done）。

### 新坑 31：private 类型的泛型父类必须同 private

`class X: NSHostingView<PrivateView>` 报"must be declared private"——
泛型参数引用 private 类型时子类可见性不得更宽。

### 23.1 追加：OBS 拖动失效真根因（allowsHitTesting 全关反噬）

用户反馈 OBS 浮窗依然不能拖动。真根因：SwiftUI 层
`allowsHitTesting(false)` 让内容整体退出 hit-test——AppKit 命中测试
找不到响应视图，mouseDown 根本不到 NSView 层，performDrag 永不触发
（上轮"NSView 层转发"的设计前提就不成立）。且文字本无交互需求，
全关命中毫无收益。

修复：移除 allowsHitTesting(false)，内容参与命中；NSView mouseDown
统一走 performDrag（加日志便于确认链路）。

### 新坑 32：allowsHitTesting(false) 会吞掉 NSView 层的 mouseDown

SwiftUI allowsHitTesting(false) 不是"事件穿透到窗口"，而是"此视图
不参与 hit-test"——若整个 contentView 内容都 false，AppKit 找不到
first responder 候选，窗口级 performDrag 的入口（mouseDown）不会发生。
需要"显示不可点 + 窗口可拖"时：保留 hit-test，在 NSView/Window 层
接管 mouseDown。

### 23.2 追加：引擎切换后识别语言不同步（didClose 时序竞争）

真根因：AppKit 里**子菜单项 action 早于 menuDidClose 派发**——
selectEngine 执行 rebuildMenu() 时 isMenuOpen 仍为 true，被
「打开中禁止替换」守卫拦截，结构重建从未发生。

修复：rebuildMenu 延迟到下一 runloop
（DispatchQueue.main.async）——彼时菜单已完全关闭，重建安全生效。
守卫本身保留（防打开中替换的 17.12 陷阱不复发）。

### 新坑 33：NSMenu 子菜单 action 与 menuDidClose 的派发顺序

action 先于 didClose。依赖 didClose 复位状态后立刻在 action 里做
"菜单已关闭"假设的操作会全部落空；跨该时序的操作用 async 延迟一拍。

### 23.3 追加：async 一拍仍不够 + MiMo 语言边界

1. **上轮 async 延迟仍失效**：下一 runloop tick 仍在 menuDidClose 之前
   （关闭动画窗口期）。加固：延迟 0.4s（> 收起动画）+ 显式复位
   isMenuOpen 后强制重建；menuDidClose 再兜底一次幂等重建
   （buildMenu 全量、重复无害）。三重保险覆盖所有时序。
2. **MiMo 中英边界**：在线引擎下 API 类型=小米 MiMo 时，识别语言表
   只列 自动/中文/英文（菜单栏 whisperLanguageSubmenu 分支 +
   TranscriptionService.languageSupport 同步），与其
   asr_options.language 能力一致；其他在线端点保持全表。

修复过程中一次替换脚本把函数头换新实现后旧函数体残留造成结构损坏——
已清理。测试 123/123；release 打包重启通过。

验证：本地→在线（MiMo）切引擎 → 识别语言变中英三项；openai 端点 →
全语言表；Apple → 语言包列表。

### 新坑 34：锚点替换脚本失败后必须回读全文再续写

部分写入后再跑第二个替换脚本，新旧实现并存会产生孤儿代码块——
编译错误只是表象，正确做法是 sed -n 读损坏区域全文、以实际文本为锚
清理，而不是凭记忆再补一刀（本轮孤儿尾巴就是这么来的）。

### 23.4 追加：菜单栏语言改动主窗口不同步（Observable 依赖缺口）+ 转录记录持久化

1. **语言不同步真根因**：设置页 body 对 asrLanguage/targetLanguage **没有
   读取依赖**——Picker selection 的双向绑定只在用户交互时写值；外部
   （菜单栏）写入时 body 不重渲染，Picker 显示旧值。引擎切换之所以
   同步正常，是因为 body 里 switch recognition.asrEngine 显式读了该属性。
   修复：body 内 `let _ = recognition.asrLanguage` / `let _ =
   translation.targetLanguage` 显式建立 Observable 追踪。

2. **转录记录开关持久化**：AppState.enableLiveTranscription 从普通
   var 改为 UserDefaults-backed computed property
   （key "enableTranscriptRecord"，默认 true）——选择 App 页/通用设置/
   菜单栏三处写同一键，重启保留。语义不变（只控历史生成，实时字幕
   始终进行）。

测试 123/123；release 打包重启通过。
验证：菜单栏切语言 → 设置页 Picker 立即变（无需重新进页面）；选 App
页关「转录记录」→ 重启应用 → 开关仍为关。

### 新坑 35：@Observable 外部写入需要 body 有读取依赖

SwiftUI + @Observable：Picker(selection:) 的绑定不建立对外部写入的
刷新订阅——body 必须显式读取该属性（let _ = x）才会因外部变化重渲染。
"交互同步、外部不同步"的 UI 症状先查这个。

### 一句话总结（第 20–23 节）

第 20–23 节完成：引擎分类事故修复与复盘、LiveTranslate 深度报告对标
（可靠性/VAD/桶化/翻译/显示/补零可调/OBS 窗，共 15+ 项）、四轮 bug
检查与死代码清理。测试 106→123。git 历史干净按功能分 commit。

---

## 24. 第十六轮会话（2026-08-23 22:00–22:40）：ASRResultNormalizer 统一识别结果层

### 需求（用户规格）

所有 ASR 引擎（whisper / qwen3asr / nemotron / apple / funasr）输出统一归一，
字幕层禁止 if whisper / if funasr / if apple 引擎分支；Provider 推理逻辑不动；
两个 commit：`refactor: add ASR result normalizer` + `refactor: unify provider
output format`；不混入 UI/Runtime/VAD/模型管理修改。

### 架构（落地形态）

```
ASRProvider（推理逻辑不动）
      ↓ 统一中间结果（ASRResult / TranscriptionResult）
TranscriptionService 出口（dispatchChunk / transcribeFileDispatch 收口）
      ↓ ASRResultNormalizer（唯一允许按引擎分支的位置）
NormalizedASRResult { segments, language, engine, metadata, fullText }
      ↓
SubtitleManager（只按 metadata.mergePolicy 行为）/ AppState / APIServer
```

新模块 `Sources/Pipeline/ASR/Normalizer/`：
- `NormalizedSegment.swift`：NormalizedSegment（id/text/startTime/endTime/
  confidence/isFinal）+ NormalizedASRResult；
- `ASRMetadata.swift`：ASREngineType（= ASRProviderEngine 的 typealias，不造
  重复枚举）、ASRTimebase（chunkRelative/sessionStart）、**ASRMergePolicy**
  （replaceTail=每轮重转录整个 tail 整段替换 / appendIncrement=流式引擎只回
  增量需跨轮累积）；ASRMetadata.default(isStreamingEngine:) 按 Provider 协议
  已声明的喂音语义折算；
- `ASRResultNormalizer.swift`：三个 normalize 入口（ASRResult 单文本 /
  TranscriptionResult 多段 / TranscriptionSegment 单段增量）+ 回迁
  toTranscriptionSegments。

### 关键修复（顺手修的真 bug）

`liveEngineStreamsIncrementally` 硬编码只认 Apple——FunASR paraformer-
streaming 同样是增量引擎（isStreamingEngine=true），却被误按整段替换策略
处理：当前句每轮被最新碎片覆盖，前半句丢失。现在合并策略由 Provider 的
isStreamingEngine 折算为新查询 `liveMergePolicy`，布尔形式保留。

### 数据结构决策

- NormalizedASRResult.fullText：文件转录兼容字段（历史库 fullText 直接取用，
  APIServer text/json 响应不变）；实时链路不用（增量语义下整段无意义）。
- 字幕显示/持久化仍是 TranscriptionSegment——归一层在边界转换
  （toTranscriptionSegments），历史库数据格式零迁移。

### 改动面（3 commit）

1. `30eb76f refactor: add ASR result normalizer`：Normalizer 模块 + 7 单测。
2. `1f09e0e refactor: unify provider output format`：transcribeChunk 返回
   NormalizedASRResult；ASRManager 合并策略读结果 metadata；SubtitleManager
   appendTail(incremental:) → (mergePolicy:)；修 paraformer-streaming bug。
3. `bcee64f refactor: normalize file transcription output`：transcribe 出口
   归一（分派主体拆至 transcribeFileDispatch）；AppState/APIServer 消费端
   回迁原格式。

测试 123→130（+7 Normalizer）。全量通过。工作区干净。

### 未做 / 下轮候选

- confidence 目前仅 Apple 有真实来源；whisper avg_logprob、sherpa 时间戳
  精细映射可后续补进 NormalizedSegment（字段已预留）。
- ASRTimebase 当前两档都由调用方加偏移（行为同旧），真正绝对时间轴引擎
  接入时才需要消费方区分。
- 规格第七节「切换模型不影响字幕渲染」的端到端验证需真机（SenseVoice /
  paraformer-streaming 实测），纯数据层已由单测覆盖。

---

## 25. 第十七轮会话（2026-08-23 22:45–23:20）：合并 StreamingContext 能力进 SubtitleManager

### 需求演变

用户先发来「新建 Pipeline/Streaming/ 层」的规格；分析后指出其与现有
SubtitleManager（pendingTailSegments/sealedSegments/mergePolicy/trimOverlap）
大面积重复，建议合并版。用户采纳：「不要创建新的 StreamingContext 层……
将 StreamingContext 的有效能力合并进 SubtitleManager」。

### 落地（3 commit）

1. `d6397d4 refactor: add subtitle streaming state`：StreamingState 枚举
  （idle/recognizing/partial/finalizing/completed）由 SubtitleManager 持有，
   在 appendTail / seal 系列 / stop / clear 中推进。用途限定日志/UI 展示/
   监控，不做并发控制（实时循环严格串行）。
2. `94e785a fix: support subtitle tail rollback`：rollbackTail(to:)——
   final 修正/缩短已显示 partial 时（Apple："ta pop" → "pop"）替换
   pendingTail 而非追加，消除「ta pop pop」脏文本。按 endTime 清理重叠旧
   tail（final 只对覆盖区间负责）；空 final 只清 tail。**注意：目前是能力
   预留，实时链路尚未接线调用（Apple 的增量基线 diff 已在 Provider 层消化
   大部分回退），接线点是后续观察实际脏文本出现后再做。**
3. `81f13c4 refactor: simplify ASR result handling`：ASRManager.startLive
   的单轮结果处理抽为 handleASRResult(_:recorder:context:)（HandleContext
   打包循环上下文）。行为逐行不变。

### 决策记录

- 不建 Pipeline/Streaming/ 目录、不建 StreamingSegment/SubtitleSnapshot：
  与 NormalizedSegment / appendTail 返回值重复，纯透传层。
- 去重逻辑零改动：Provider 基线 diff + trimOverlap 保持原样（规格明确禁止
  复制一套 Streaming 去重算法）。
- 测试 130→136（+2 状态机 + 4 rollback）。

### 未做 / 下轮候选

- rollbackTail 生产接线：若实测出现「partial 残留 + final 缩短」的显示
  脏文本，在 handleASRResult 中对 isFinal 且短于当前 pendingTail 文本的
  归一结果调 rollbackTail。
- StreamingState 接入浮层 UI（如显示「识别中…」状态点）。

---

## 26. 第十八轮会话（2026-08-24 00:30–00:50）：ASRCapability 能力描述层

### 需求

统一 ASR 引擎能力描述（streaming/partial/timestamp/语言/网络/推荐模式），
UI 与未来自动路由经 Capability 查询；Provider 不动、不放推理/加载/状态逻辑。

### 落地（2 commit）

1. `12e279b refactor: add ASR capability model`：Pipeline/ASR/Capability/
   ASRCapability.swift——ASRMode（realtime/balanced/accuracy）+ ASRCapability
   纯数据结构 + supportsLanguageSelection 派生字段 + summaryEntries
  （设置页 ✓/△ 列表数据源）。
2. `c7b83bd refactor: add ASR capability registry`：ASRCapabilityRegistry
  （引擎→能力唯一查询口，静态注册，缺失 debug 断言+兜底）+
   ASRPerformanceProfile（速度档位/内存量级/setup 成本）。
   FunASR 按所选模型折算（paraformer-streaming 流式、语言按模型族）。

### 数据事实依据（防编造）

- timestamp=true 仅：whisper（原生段）、apple（段 range）、funasr
 （sherpa token 级 timestamps）；Qwen/Nemotron 为字符估算 → false；
- streaming=true：apple 恒真；funasr 随模型（与 isStreamingEngine 同源）；
- 语言表：whisper 全表来自 CWhisper 运行时查询；Qwen 自动检测不可枚举
 → 空表（supportsLanguageSelection=false）；Apple 跟随系统语言包 → 空表。

### 测试

144（+8）：完备性不变量（规格第九节）、streaming 描述与 Provider 声明
一致性、网络需求唯一性（仅 online）、字段语义、自定义注入覆盖、兜底安全。

### 未做 / 下轮候选

- 设置页接 Capability 渲染（✓ 实时识别 / △ 时间戳 列表）——本次按规格
  禁止混入 UI 重构，summaryEntries 已备好数据源；
- 自动路由（任务 → capability 查询 → 推荐模型）仅为数据预留。

---

## 27. 第十九轮会话（2026-08-24 01:00–01:25）：能力描述层接入设置页

### 需求

ASRCapability 仅作描述/展示/调试（禁止自动选模型/推荐/性能决策）；
设置页能力展示改动态读取 summaryEntries；UI 不感知引擎（移除硬编码分支）。

### 落地（1 commit：aeeddf3 feat: display ASR capability metadata in settings）

- ASRCapability 补 summaryEntries（上轮汇报说有此字段，实际漏写——本轮
  如实补上）：推荐场景 / 实时出字 / 原生时间戳 / 语言策略 / 运行位置；
- ASRCapabilitySummaryView：通用 ✓/△ 渲染视图（SettingsPages.swift 内，
  紧邻 StatusRow）；无 if engine == .xxx 分支；
- 接入四处：识别引擎 Section（engineHint 下方）、本地模型列表底部
 （当前模型能力）、Apple Speech 区块头、在线 API 启用后头部；
- TranscriptionService.engineType(forModelPath:) 新公开口：把 private
  engine(forPath:) 的判定结果转 ASREngineType（设置页与转录调度同一
  事实源），行为零改动。

### 测试

148（+4）：summaryEntries 全引擎完备性、网络需求文案一致性、语言条目
策略、engineType 与 debugEngineDescription 判定一致性。

### 边界遵守

未动 Provider/Runtime/ASRManager/SubtitleManager/Capability 模型字段；
无自动选择逻辑。新引擎接入流程 = 注册表加一条注册，UI 零修改。

---

## 28. 第二十轮会话（2026-08-24 02:00–03:00）：远程 ASR 引擎 + Silero 神经网络 VAD

### 背景

LiveTranslate 报告缺口分析后确认两个真缺口，用户拍板「两个都做」。
依赖报告：Silero VAD 模型 ~2.2MB（MIT，sherpa-onnx releases 运行时下载）；
远程 ASR 零新增依赖。勘误：此前说的 FSMN-VAD 是 FunASR 生态模型，
sherpa-onnx C API 未暴露；实际可用为 Silero/Ten-VAD 两族。

### A. 远程自托管 ASR 引擎（22c3b42 feat: add remote self-hosted ASR engine）

- `.remote` 引擎档：RemoteASRProvider（句子缓冲 + 请求队列 + 结果合并，
  与 Online 同构）；OpenAI 兼容 /audio/transcriptions 协议，密钥可选；
- **配置活动源机制**（核心设计）：OnlineASRConfig 的读取口感知
  isActiveSourceRemote，远程激活时转发 RemoteASRConfig——OnlineASRService
  29 处引用零改动复用整个请求栈（WAV 编码/上传/解析/超时/错误分类）；
  unloadModel 复位在线源；
- 接线面：resolveEngine/resolveLiveEngine（端点未配置回落本地）、
  dispatch、shouldChunk（remote 与 online 同不参与分片）、preload、
  shutdown/unloadLiveModel、languageSupport（.selectable 全表）；
- UI：设置页「识别方式」四项 + RemoteASRSettingsSection（端点/密钥/
  模型名/测试连接——测试期间临时激活活动源复用在线连通性检查）；
  菜单栏引擎子菜单加「远程」；能力层注册 .remote（网络引擎）。

### B. Silero 神经网络 VAD（feat: add Silero neural VAD...）

- SherpaVAD（Pipeline/Audio/）：sherpa-onnx v1.13.6 C API 的
  VoiceActivityDetector 封装（符号已在 no-tts 裁剪版静态库中验证存在）；
  512 窗口步进喂入 / Detected() 查询 / 懒加载 + 60s 失败冷却；
- **判定链融合原则：可选增强，不可用时行为逐位不变**：
  · 密度门 ≥0.25 时经 detectSpeech 确认——音乐底噪（能量过门但非人声）
    改判静音省算力；
  · 能量门 ≤skipThreshold 时 detectSpeech==true 则放行送 ASR——低响度
    语音不再误跳过；
- 设置页「音频处理」下载行（GitHub releases 直链，原子写入模型目录）；
  startLive 时 reset 会话。

### 测试与验证状态

148 全过（testOnlineRequiresNetworkOthersLocal 更新为双网络引擎语义）。
**未真机验证项（下轮优先）**：① 远程端点实际请求（whisper.cpp-server
对拍）；② silero_vad.onnx 实际下载后 detector 建立、音乐场景静音判定
对比；③ 菜单栏切远程 → 语言子菜单同步。

### 下轮候选

- VAD 电平监控条（调试面板实时显示 RMS+人声概率，调参所见即所得）；
- 首启引导向导（按系统语言预选下载源 + 倒计时自动开始）；
- 会话文本落盘（original/translation/all 三文件 tail -f 可跟）。

---

## 29. 第二十一轮会话（2026-08-24 03:20–04:00）：翻译提示词体系

### 需求

硬编码翻译 System Prompt 升级为可配置 Prompt 管理（预设/变量/持久化），
只属于翻译层；实时行为（队列/并发/超时/三连败）与 SubtitleManager 零改动。

### 落地（4 commit）

1. `4d221d4 feat: add translation prompt builder`：PromptBuilder——变量
   替换唯一收口（{source_lang}/{target_lang}/{text}；缺失安全、不改模板、
   未知占位符保留）；embedsText 判定模板是否内嵌待译文本。
2. `b8cdaed feat: add translation prompt presets`：预设迁移到 Pipeline 层
  （规格三预设变量化 + 保留旧四场景）；持久化 translationPromptPreset
   新键 + 模板沿用 systemPrompt 键（不新增访问层）；TranslationService
   systemContent 接入 PromptBuilder——三铁律/格式指令/上下文双路径追加
   行为不变。
3. `9815767 feat: add translation prompt settings`：TranslationPromptEditor
  （预设 Picker 即时加载 / 等宽编辑区 / 变量点击追加 / 恢复默认 / 保存）；
   编辑缓冲与持久化分离（保存才写回；与预设不同自动标记自定义）。
4. `test: add translation prompt coverage`：10 单测（变量/安全/预设
   完备性/规格模板/Apple 隔离源码级守护）。

### 设计决策

- **变量替换收口**：只在 TranslationService.systemContent 构造处调用
  PromptBuilder（所有 LLM 路径——本地/在线/流式/批量——汇聚点）；
  Provider 零改动。
- **{text} 语义**：变量化模板整体作 system（文本嵌入其中），user 消息
  仍发编号原文——批量 JSON 解析依赖编号行，不能把文本从 user 抽走。
- **源语言变量值**：实时场景 ASR 未显式给出源语言，统一填
  "the detected source language"（避免编造语种）。
- **Apple Translation 隔离**：不经过 PromptBuilder（源码级测试守护）。
- 旧「提示词预设」Menu + 单行 TextField 移除，由编辑器替代。

### 测试

148→158。全量通过。工作区干净。

---

## 30. 第二十二轮会话（2026-08-24 05:00–05:30）：翻译预设 8 场景升级

### 需求

彻底替换旧翻译预设为 8 个内置场景预设（四字段结构 id/name/description/
prompt），默认预设设为「视频字幕」；用户已有 Prompt 配置必须保留；
PromptBuilder/Provider/Apple 零改动。

### 落地（0449b3d feat + test commit + 本节 docs）

- TranslationPromptPreset 重写：8 预设（daily-chat / video-subtitle /
  live-stream / film-drama / game / tech-it / news / business），全部
  变量化模板（{source_lang}/{target_lang}/{text}）；customID="custom"
  编辑态标记；defaultID="video-subtitle"（规格第四节建议模板）；
- 用户配置兼容：loadPersisted 三分支——首次安装（两键皆空）落默认
  视频字幕；已有 Prompt 原样保留（显示态按内容匹配预设，全等才高亮，
  否则自定义态）；残留旧 id 以内容为准；
- 设置页：「翻译风格」选择器（8 预设 + 自定义）+ 预设描述行 +
  编辑器/恢复默认/保存行为不变；
- 测试 158→163：预设完整性 / 默认预设模板 / 切换链路 / 兼容三分支 /
  Provider 唯一收口守护 / Apple 隔离守护。

### 备注

工作区中发现同规格改动已先行完成大半（预设文件 + 设置页），本会话
核对规格符合性、补齐测试适配与提交。TranslationService 只读 systemPrompt
键（模板全文），不感知预设 id——运行时零改动成立。
