# WhisperASR 架构演进与全景可优化项清单

> **实施状态提醒（2026-09-11 复核；2026-09-19 补充「六、2 工具链检测已部分落地」「六、3 C target 编译单元已落地」）**：下表中多条优化的**代码已落地且带单测，
> 但没有接进管线**——清单里写的"拟定方案"有些已经写完了，别重复实现。
> 准确名单（含未接线模块与建议接线顺序）见 `docs/HANDOFF.md` 第 32 节。
>
> | 已落地未接线 | 对应本清单条目 |
> |---|---|
> | `SPSCFloatRingBuffer` + `RealtimeAudioIngest` | 一、1 无锁环形缓冲 |
> | `MetalSubtitleRenderer` + `SDFGlyphAtlas` + `MetalSubtitleController` | 三、1 Metal 直接渲染字幕（含字词级高亮） |
> | `TranscriptionIndexStore`（SQLite3 原生 C-API） | 五、1 轻量元数据索引 |
> | `OpusAudioArchiver`（24kbps Opus 流式归档） | 五、2 录音文件压缩 |
> | `BoundedBatchTranslationManager` | 二、2 批量并行（翻译侧） |
> | `KVCacheSession` + `MLXKVBackend` | 二、1 动态 KV Cache 复用（等 MLX 引擎） |
>
> 另经代码搜索确认**尚未开始**的条目：
> - 一、2 预加重/高通滤波（无 `preEmphasis`/biquad 类实现）
> - 一、3 AEC 回声消除（无 `AVAudioEngine` VoiceProcessing / AEC 相关代码）
> - 四、2 离线 LLM 原生集成（依赖表里没有 llama.cpp；本地翻译仍走外部 HTTP 服务）
> - 二、3 智能动态引擎路由 2.0 —— 注意：**基础版已存在**
>   （`ASREngineSelection.auto` 按模型文件类型路由 + 连续失败降级），
>   未做的是"按语言特征/电源状态动态切换"那一层。

本清单系统性整理了 WhisperASR 在**音频管线**、**ASR 识别引擎**、**实时字幕与 UI**、**大模型翻译与纪要**、**存储与数据架构**以及**工程发布**等 6 大维度的前瞻优化建议与落地技术方案。

---

## 🎧 一、 音频采集与预处理管线 (Audio Pipeline)

| 优化项 | 现状分析 | 拟定技术落地方案 | 预期收益 | 优先级 |
|---|---|---|---|---|
| **1. 环形无锁缓冲 (Lock-Free RingBuffer)** | 当前采用 `OSAllocatedUnfairLock` 配合逻辑游标 `headIndex` 摊还整理。 | 引入基于 C/Swift 原子操作（`stdatomic` / `Atomic`）的定长 Single-Producer Single-Consumer (SPSC) 环形缓冲区，采集线程 100% 零锁写入。 | 音频中断回调彻底摆脱任何并发锁，延迟下探至亚微秒级，完全消除潜在音频丢帧。 | 🟢 中期 |
| **2. 音频预加重与高通滤波 (Pre-emphasis & HPF)** | 仅依赖能量与 ZCR 硬阈值过滤高频噪声。 | 在 48kHz → 16kHz 重采样后追加 80Hz 一阶高通滤波与预加重滤波器（Pre-emphasis: $y[n] = x[n] - 0.97 x[n-1]$）。 | 滤除空调风噪与环境低频杂音，显著提升 Whisper 和 Qwen 在嘈杂环境下的首字识别率。 | 🟡 短期 |
| **3. 多麦克风回声消除 (AEC 硬件级适配)** | 当前系统音频与麦克风为简单线性混音加和。 | 集成 `AVAudioEngine` 的 `AUVoiceProcessing`（VoiceProcessingIO）或 WebRTC AEC3 回声消除单元。 | 扬声器外放会议声音时，麦克风不会录入重复的声音，杜绝 ASR 发生回声复读。 | 🔴 高优先 |

---

## 🧠 二、 ASR 识别引擎与推理调度 (Multi-Engine Inference)

| 优化项 | 现状分析 | 拟定技术落地方案 | 预期收益 | 优先级 |
|---|---|---|---|---|
| **1. 动态 KV Cache 复用 (Prompt Cache)** | 无状态引擎（Whisper / Qwen3）每轮 pass 重转录时从 chunk 起点全量算 Prompt。 | 针对 Qwen3 / Whisper 维护会话级 Prefix KV Cache，尾部增量音频仅计算新 token 的注意力矩阵。 | 实时识别单轮推理计算量降低 40%~60%，高频出字 CPU/GPU 功耗大幅下降。 | 🔴 高优先 |
| **2. 动态 Batching 多文件并行转录** | 拖拽批量文件时采用顺序队列单文件串行推理。 | 在 GPU 显存富余时（如 M Pro/Max/Ultra），开启 2~4 路并行批处理流，基于 Metal 并发 command buffer 执行。 | 批量转录数小时长音频或多文件时，整体耗时缩短 50% 以上。 | 🟡 短期 |
| **3. 智能动态引擎路由 (Smart-Steering 2.0)** | 当前由用户手动指定单一引擎，仅在网络失败时降级。 | 实现根据输入语言特征（中文方言/英文/日韩）、音频长度与电源状态（电池/插电）动态无缝切换最佳引擎（如：短语音走 Apple Native，长难句走 Qwen3-ASR）。 | 极致平衡电池续航、出字速度与复杂长句准确度。 | 🟢 中期 |

---

## 🪟 三、 实时字幕与交互渲染 (Subtitle & Floating Overlay)

| 优化项 | 现状分析 | 拟定技术落地方案 | 预期收益 | 优先级 |
|---|---|---|---|---|
| **1. Metal 直接渲染字幕 (Metal HUD Layer)** | 字幕渲染依赖 SwiftUI 的 `Text` 布局与动画树。 | 针对大字号高频刷新的长段同传，使用 `CAMetalLayer` 或 CoreText 纹理缓存进行直接绘制。 | 60/120fps 满帧丝滑打字机刷新，CPU 占用率从 3~5% 进一步压降至 <1%。 | 🟢 中期 |
| **2. 智能字词对齐高亮 (Word-Level CTC/Attention)** | 当前按句子粗粒度高亮。 | 提取 Whisper / SenseVoice 产生的词级时间戳（Word-level timestamps），实现类似 Apple Music 歌词的词级平滑逐字推进。 | 播放与核对长音频时定位精确到具体单词/单字。 | 🟡 短期 |

---

## 🌐 四、 大模型翻译与会议纪要 (LLM Translation & Summary)

| 优化项 | 现状分析 | 拟定技术落地方案 | 预期收益 | 优先级 |
|---|---|---|---|---|
| **1. 句尾合并批量防截断 (Sentence Window Sliding)** | 每句独立单飞翻译，有时上下文关联度不足。 | 引入两句滑窗（`previousContext` + `currentSentence`），在 Prompt 中注入上一句译文，保持上下文主谓语一致。 | 解决代词指代不明（如 "He/It"）、术语前后翻译不一致的难题。 | 🟡 短期 |
| **2. 离线 LLM 小模型原生集成** | 本地翻译依赖外部 Ollama / LM Studio HTTP 端口。 | 集成 `llama.cpp` 预编译静态库，直接在 App 内加载 Qwen2.5-1.5B/3B GGUF 模型进行完全独立的端侧离线翻译。 | 用户无需安装配置任何第三方工具即可开箱使用离线翻译。 | 🔴 高优先 |

---

## 💾 五、 持久化与数据架构 (Storage & Architecture)

| 优化项 | 现状分析 | 拟定技术落地方案 | 预期收益 | 优先级 |
|---|---|---|---|---|
| **1. SQLite / GRDB 轻量元数据索引** | 当前 500+ 文件已实现多核并行解码，但仍需遍历 500 个 JSON 文件。 | 引入单文件 `manifest.sqlite` 仅记录 `(id, title, date, duration, preview)`，条目详情保留独立 JSON。 | 即使历史会话增长至 10,000+ 条，App 冷启动耗时依然稳定在 2ms 级别。 | 🟡 短期 |
| **2. 录音文件增量压缩 (Opus/AAC-HE)** | 当前保存为标准 48kHz AAC (M4A)。 | 在转录完成后提供一键「无损/低码率压缩」选项，转为 24kbps Opus 格式。 | 历史录音文件体积减少 70%，节省宝贵的 Mac 磁盘空间。 | 🟢 中期 |

---

## 📦 六、 工程发布与自动化 (DevOps & Tooling)

| 优化项 | 现状分析 | 拟定技术落地方案 | 预期收益 | 优先级 |
|---|---|---|---|---|
| **1. GitHub Actions 自动化多架构打包** | 依赖本地脚本打包 DMG / Release。 | 编写标准 CI 工作流，自动拉取依赖、编译 `arm64` 静态库、执行 notarization 公证并产出 dmg。 | 发布流程全自动，杜绝本地环境差异导致的分发问题。 | 🟡 短期 |
| **2. 统一 Xcode 环境变量检测** | **已部分落地**：`Scripts/build_release.sh` 内置工具链探测——`DEVELOPER_DIR` 指向的工具链用 `xcrun --find swiftc` + `libSwiftUIMacros.dylib` 存在性双探测，不可用（典型：Xcode 许可未接受）时自动回退为「CLT 工具链 + `-Xswiftc -plugin-path <Xcode 宏插件目录>`」，并打印可操作修复指引；`ARCHS` 多架构请求也会先探测 xcframework 切片。**仍未做**：`swift test` 侧无同等探测（测试仍需手动 `DEVELOPER_DIR=... swift test`），CI 与本脚本的探测逻辑各写一份。 | 把探测抽成 `Scripts/toolchain.sh`，供 `swift build` / `swift test` / CI 工作流共用（`Package.swift` 层无法感知工具链，故仍收口在脚本层）。 | 提升跨设备协作与开源贡献者的开箱测试体验。 | 🟡 短期 |
| **3. 纯头文件 C target 的编译单元** | **已落地**：`CRealtimeAtomics` 曾只有 `CRealtimeAtomics.h`（原子 API 全是 `static inline`，链接期不产生符号）。新的 swiftbuild 构建引擎对纯头文件 target 不产出对象文件，链接期报未定义符号。 | 补一个真实编译单元 `SourcesC/CRealtimeAtomics/CRealtimeAtomics.c`（含 `cra_shim_version()`），让 target 产出 `.o`。 | 跨 swiftbuild 版本稳定链接，无锁环形缓冲接线时不再被构建系统卡住。 | ✅ 已落地 |
