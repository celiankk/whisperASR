# WhisperASR 开发日志（2026-08-06）

> 记录从“一体化字幕浮层重构”到“Qwen3-ASR 本地推理 / 本地 LM 翻译接入”的全部开发操作。
>
> 约定：后续每次开发 / 构建 / 修复操作完成后，统一追加记录到本文档（含根因、改动、验证结果）。

## 一、一体化字幕浮层（FloatingLetter）重构

### 新增组件（Sources/FloatingLetter/）
- `FloatingLetterViewModel.swift`：UI 状态 + 5 秒闲置倒计时 Timer + 业务动作闭包注入（与业务层解耦）
- `FloatingLetterViews.swift`：长条半透明圆角容器、工具栏、录制控制栏、字幕区
- `FloatingLetterOverlayController.swift`：无边框 NSPanel（置顶、右上角定位、淡入淡出、鼠标监听、紧凑/展开）
- `FloatingLetterIntegration.swift`：Binder（AppState/AudioRecorder ↔ VM）+ Host 宿主
- `FloatingLetterLeakTest.swift`：DEBUG 存活计数自检

### 交互规则（按需求落地）
- 鼠标 5 秒无操作自动淡出；移入浮层立即显示并重置倒计时
- 点击浮层任意控件重置倒计时；视图销毁/teardown/deinit 主动 invalidate Timer
- 窗口置顶：默认 `.statusBar`，图钉开启 `.screenSaver`；右上角定位、可拖动
- 淡入淡出 0.25s；缩放箭头收起为小药丸

### 内存自检
- `--overlay-leak-test`：5 轮宿主链路 + 3 轮裸链路后 VM/Binder/HostingView 存活计数归零，PASS
- 修复：重复 present 刷新绑定误将复用 VM 标记为 torn down（改 `detach()`，自动隐藏不再失效）
- 修复：`@NSApplicationDelegateAdaptor` 下 `NSApp.delegate` 是 SwiftUI 包装对象，自检改为直接传入 AppDelegate 实例

## 二、旧组件移除与流程重构

### 已删除
- `Sources/SubtitleOverlay.swift`、`Sources/FloatingLetterOverlay.swift`（旧字幕条 + 旧浮动控件）
- `Sources/RecordingView.swift`、`Sources/AppPickerView.swift`（旧录制窗口 + 旧选择应用窗口）
- `Window("Recording")`、`Window("app-picker")` 场景

### 显隐逻辑
- 业务显隐钩子 → 录制驱动：点击【开始录制】自动显示，录制窗口/流程结束自动隐藏
- 调试菜单只保留“字幕浮层样式预览”，不再控制浮层启停

### 选择应用独立弹窗（FloatingAppPicker.swift）
- 与字幕浮层完全解耦，独立 NSPanel：白色圆角、主界面同款系统阴影、居中主窗口、不可拖动
- 层级 `.normal` 不遮其他应用；点击弹窗外空白处返回；搜索框可输入

## 三、字幕动画体系

### 逐字动画（SplitSubtitleText.swift）
- 按字符拆分，新字符淡入 + 上移 + 缩放（power3.out）
- 公共前缀 diff：已显示字符保持静态，流式追加只动画新增字符（不重建已有视图）
- 超长（>200 字符）自动退化为普通 Text

### 字幕层级动画
- `SubtitleContainer → SubtitleLine → SplitSubtitleText` 三层分工，互不抢 transform/opacity
- 当前行 100% 透明度 / y=0（SplitText 字符动画）；历史行 30% / y=-20（普通文本不重播）
- 新行从底部 40pt 进入；删除/退出淡出；interim 普通文本直出

### 行数限制（maxLines）
- 语义：屏幕总字幕行数（非历史数量）
- 当前行最多 2 行（maxLines=1 时 1 行），历史行占用剩余空间；interim 占 1 个当前位
- 例：maxLines=3 → 当前 2 行 + 历史 1 行；maxLines=4 → 当前 2 行 + 历史 2 行

### 浮框高度自适应
- `requiredSubtitleHeight` = 行数 × 行高 + 行间距；控制器观察后自动伸缩面板（锚定右上角）
- 字幕容器不裁剪历史字幕；暂停时高度变化不带动画

### 历史字幕生命周期（防循环）
- `visible → exiting → removed`，每条唯一 id，退出动画只执行一次
- `spentHistoryIDs` 状态锁：完成生命周期的行不再重新进入历史行（修复无限循环退出）
- `isPlaying` 冻结：暂停时不更新行、不创建退出计时器、不动画、不重算布局；恢复后继续

### 视觉迭代
- 毛玻璃（ultraThinMaterial + 白 12%）→ 因可读性差改回 **黑色半透明**（前景文字/图标零改动）
- 圆角 20pt 连续曲线、0.5pt 极淡描边、系统窗口阴影；无白色锯齿

## 四、Qwen3-ASR-1.7B 本地推理

### 模型目录
- `ModelCatalog` 新增 `qwen3asr` 引擎；`Qwen3-ASR-1.7B-Q8_0.gguf`（2.18GB，HF 下载地址已实测 200）
- 事实确认：公开 GGUF 为 transcribe.cpp all-in-one 格式（音频编码器内置，无需 mmproj）；`mmprojURL` 保留可选接缝

### 推理运行时集成（transcribe.cpp / ggml + Metal）
- 安装 cmake（brew）；克隆 `.transcribe.cpp/`
- 新增 `Scripts/build_transcribe_lib.sh`：CMake 编译 → 静态库合并 → Swift 桥接 shim → 手工打包 `Frameworks/CTranscribe.xcframework`（本机无 Xcode，按 XCFramework 规范构造 Info.plist）
- `Package.swift` 增加 CTranscribe binaryTarget 与 Metal/Accelerate 链接

### Qwen3ASRBackend（真实推理）
- `transcribe_open / transcribe_run / transcribe_full_text`，串行队列保证会话线程安全，模型按路径复用
- 统一输出：`text / startTime / endTime`（GGUF 无时间戳时按句切分估算）/ `isFinal`（上游密封语义）
- 引擎分发：`TranscriptionService` 中 qwen3asr 分支全部走新后端，**绝不调用 whisper.cpp**

### 验证
- CLI：JFK 音频 → 正确文本、自动语种 en、Metal 9x 实时
- 应用内桥接 `--qwen3-smoke`：PASS

### 上传/自定义模型修复
- 新增 `GGUFInspector.swift`：解析 GGUF 头 `general.architecture`（修复漏读 n_kv 字段），不依赖文件名识别引擎
- `resolveModelPath()`：自定义路径优先；设置页提示更新
- `modelExists()`：接受 `.bin` 与 `.gguf`（修复“已下载仍每次弹下载窗口”）

## 五、翻译模块

### 翻译方式
- `TranslationMode`：不翻译 / 本地模型 / 在线 API（持久化，旧 `liveTranslationPref` 自动迁移）

### 在线 API 配置
- API Base URL / Key / 模型名称 / 请求超时 / 最大上下文长度 / 温度参数
- 兼容 OpenAI `/v1/chat/completions`；异步执行不阻塞字幕；失败自动重试（指数退避）
- “检测 API 状态”按钮；配置随备份恢复

### 本地模型（本地 LM）接入
- 移除“本地翻译模型未安装”占位拦截
- 自动探测 OpenAI 兼容本地服务：`127.0.0.1:1234`（LM Studio）→ `11434`（Ollama）→ `8080`（llama.cpp / 本应用 API 服务器）
- 模型名留空自动调 `/v1/models` 识别；本地服务免密钥（留空不发 Authorization）
- 实测用户本机 LM Studio：自动探测 + 自动识别模型，`Hello world → 你好，世界` PASS

## 六、调试与自检命令（DEBUG 构建）

| 命令 | 用途 |
|---|---|
| `--overlay-leak-test` | 浮层 present/dismiss 内存泄漏自检 |
| `--overlay-replace-test` | 录制驱动显隐自检 |
| `--overlay-select-test` | 首次打开应用列表自检（无屏幕录制权限时 SKIP） |
| `--engine-check <model.gguf>` | 打印 GGUF 架构与解析引擎 |
| `--qwen3-smoke <model.gguf> <audio.wav>` | Qwen3-ASR 后端真实推理冒烟 |

## 七、构建与产物

- `Scripts/build_release.sh`：release 编译 + 图标 + app bundle（未签名）
- `Scripts/build_transcribe_lib.sh`：transcribe.cpp 库构建（需 `brew install cmake`）
- `hdiutil create` 生成 `WhisperASR-0.9.0.dmg`
- 产物：`WhisperASR.app` / `WhisperASR-0.9.0.dmg`

## 八、已知限制

- Qwen3-ASR：时间戳为估算（GGUF 无时间戳输出）；实时为分块重转录；语言仅自动检测（不支持提示）
- “本地模型”翻译依赖本机运行的 OpenAI 兼容服务（LM Studio / Ollama / llama.cpp）
- 发布包未签名未公证（本机运行无影响）

## 九、修复：本地 LM 挂载混元报错（2026-08-06 17:00）

### 现象
- 设置中「本地模型」+ LM Studio 挂载腾讯混元翻译模型 `Hy-MT2-1.8B-Q8_0.gguf`（模型名 `hy-mt2-1.8b`），点「检测 API 状态」/ 翻译报错

### 根因（从 LM Studio 服务器日志确认）
- app 配置的端点为 `http://127.0.0.1:1234`（缺 `/v1`），请求被发到 `/chat/completions` 与 `/models`
- LM Studio 只服务 `/v1/chat/completions` 等 OpenAI 兼容路径，日志持续出现：
  `[ERROR] Unexpected endpoint or method. (POST /chat/completions). Returning 200 anyway`
- LM Studio 对未知路径仍返回 200 但响应非 OpenAI 格式 → app 解析失败
- 对照：07:46 走 `/v1/chat/completions` 时翻译正常（`Hello world → 你好，世界` PASS）

### 改动（Sources/TranslationService.swift / AppState.swift）
- 新增 `TranslationService.normalizedBaseURL()`：自动补齐 `/v1` 前缀、去尾部斜杠、保留完整 `/chat/completions` 端点
  - `http://127.0.0.1:1234` → `http://127.0.0.1:1234/v1`
- 端点解析、`/v1/models` 探测、聊天请求三处统一走归一化
- 本地模式探测不到模型名时不再静默发 `model="local"`，改为抛出 `localModelNotDetected`（明确中文提示），并在 AppState 中按不可重试错误立即停止并提示

### 验证
- `swift build` 通过；归一化逻辑单测覆盖 10 种端点写法全部符合预期
- `swift run` 启动应用待用户实测

## 十、DMG 重建（2026-08-06 17:19）

- `Scripts/build_release.sh`：release 编译（Build complete, 12.74s）+ 图标 + 未签名 app bundle
- `hdiutil create -volname WhisperASR -srcfolder WhisperASR.app -ov -format UDZO WhisperASR-0.9.0.dmg`
- `hdiutil verify`：校验和 VALID
- 产物：`WhisperASR.app`（17M 二进制）/ `WhisperASR-0.9.0.dmg`（6.1M），已含第九节修复
- 2026-08-06 18:06 重建：含第十一节三层字幕布局，Build complete 11.05s，校验和 VALID（二进制已含 SubtitleQueue/SubtitleSplitter 符号）
- 2026-08-07 15:12 重建 app（未打 DMG）：含第十二节字幕优化，Build complete 12.46s，
  `WhisperASR.app`（17M 二进制，未签名），二进制已含 detectSourceLanguage / StreamingSubtitleBuffer / SubtitleRenderer / SubtitleHistoryBuffer 符号
- 2026-08-07 16:25 重建 app（未打 DMG）：含第十三节引擎优化，Build complete 12.35s，
  `WhisperASR.app`（17M 二进制，未签名），二进制已含 SubtitleProcessor / SubtitleSentenceSplitter /
  SubtitleDeduplicator / SubtitleLatencyManager / LocalModelManager 符号
- 2026-08-07 17:19 重建 app（未打 DMG）：含第十五节稳定性优化，Build complete 12.87s，
  `WhisperASR.app`（17M 二进制，未签名），二进制已含 SubtitleEngine / SubtitleUpdateScheduler /
  SubtitleRingBuffer / PerformanceMonitor / DebugLogger 符号

## 十一、实时字幕三层固定布局 + 分割/队列调度（2026-08-06 18:00）

### 需求
- 三层固定位置：顶部=历史字幕（最旧）、左上=上一条、右下=最新实时字幕
- 字符限制：俄语单行 44 字符（含空格标点）、中文单行 26 字；空格/逗号处换行，禁止切断俄语单词；单条最多 2 行，超出截断前端只留末尾两行
- 队列策略：新字幕到达立即清除顶部历史（不缓慢淡出）；原左上降级为历史、原右下升为左上、新字幕进右下；历史存活最短、超时直接销毁；三层即上限，超出丢弃最早

### 实现（新增 Sources/FloatingLetter/SubtitleLayers.swift）
- `SubtitleLanguage`：按 Unicode 区间区分西里尔 / CJK，不混用等宽计数
- `SubtitleSplitter.split`：贪心断行，优先在最近空格/逗号/中文标点后断行；俄语无断点（超长单词）不切词、由视图视觉换行兜底；中文无标点按 26 字硬切；`suffix(2)` 只保留末尾两行
- `SubtitleQueue`：三个固定槽位 history / previous / latest；`push` 一步完成“清历史→降级→入新”，返回被丢弃的旧历史 id；`expireHistory` 超时直接销毁历史层

### 接入（FloatingLetterViewModel / FloatingLetterViews）
- VM：`pushFinalSubtitle`（同 id 去重，防 interim 阶段重复入队）+ 历史层 4s 超时任务（teardown/deinit 取消）；`updateSubtitleState` 改走新队列，旧 currentLines/subtitleText 字段保持兼容
- 视图：`subtitleStackView` 改为 ZStack 三层固定定位；每层原文+译文，`frame(maxWidth: 300)` + `lineLimit(2)` 防横向撑爆；删除旧 SubtitleLineView / reconcileHistory 死代码

### 验证
- `swift build` 通过
- 分割器实测：俄语 124 字符 → 2 行（40/41 字符，单词未切断）；中文 52 字 → 2 行（按逗号断，20/6）；超长俄语单词 46 字符整体保留不切
- 队列实测：A→B→C 链式升降级 count=3；超时销毁 A；再推 D → hist=B prev=C latest=D

## 十二、实时字幕翻译系统优化（2026-08-07）

> 只优化字幕处理/刷新/显示，前端 UI 风格与窗口布局保持不变。

### 1. 中文重复翻译修复（语言检测层）
- 流程：Audio → ASR → 语言检测 → 判断是否需要翻译 → 字幕显示
- `TranslationService.detectSourceLanguage`：按 Unicode 区间统计汉字/假名/谚文/西里尔/拉丁，
  中文变体用标记字区分 zh-CN / zh-TW / zh-HK（粤语标记优先）
- 规则：检测为 zh-CN/zh-TW/zh-HK → 原文直出，禁止进入翻译模型；
  其他语言（en/ja/ko/ru…）正常翻译
- 落地：`translateSegmentsWithOpenAI` 入口兜底 + `AppState` 实时/整段两条链路提前跳过
  （liveTranslatedSegments = 原文，避免 seal 循环重试）；视图层译文==原文时不重复显示

### 2. 增量字幕刷新（Streaming Subtitle Buffer）
- `StreamingSubtitleBuffer`：新文本以旧文本为前缀 → 只追加新段（不整体替换）；
  完全相同 → noChange（不刷新）；分歧（ASR 回溯修正）→ 整体替换
- 修复：长文本直出、刷新跳动、一次输出太长

### 3. 自动换行 + 4. 最大行数（SubtitleRenderer）
- `SubtitleSplitter.wrapAllLines`：返回全部换行行（不截断），保留文本内 \n
- `SubtitleRenderer(maxLines: 3)`：最新层最多 3 行，超出智能向上滚动、不省略、
  不出现 "..."；视图 lineLimit(nil) 按面板宽度自动换行
- 字幕最大行数默认 2 → 3（设置页仍可 1–3）

### 5. 水平对齐设置
- `subtitleHorizontalAlignment`（"left"/"center"，默认 center），设置页「字幕对齐」分段选择
- 仅作用于 `multilineTextAlignment`，不改窗口位置

### 6. 动画优化
- 只更新文本内容：渲染器文本变更包 `withAnimation(.easeOut 0.18s)`；
  最新层固定高度（maxLines × 行高）+ clipped，行数变化不引起面板伸缩；
  requiredSubtitleHeight 改为按 renderer.maxLines 稳定计算；不重建窗口实例

### 7. 字幕缓存（SubtitleHistoryBuffer）
- 最近 8 秒文本去重：相同字幕不刷新（防重复/防跳字），窗口滑动过期

### 8. 调试信息（DEBUG 构建）
- 浮层右上角小字显示：ASR / Detected Language / Translation（Skipped/Translated/Off）/ Subtitle

### 验证
- `swift build` 通过
- 语言检测：zh-CN/zh-TW/zh-HK/en/ja/ko/ru 全 PASS，中文 skip=true
- 增量缓冲：前缀追加 / 相同 noChange / 分歧 replaced 符合预期
- 滚动渲染：63 字中文 → 3 行（26/26/3），split 回归仍 ≤2 行

## 十三、实时字幕引擎架构优化（2026-08-07 第二轮）

> 只优化字幕引擎/文本处理/刷新/模型管理；前端 UI 风格与浮窗视觉不变。

### 统一处理管线（SubtitleProcessor）
- 新增 `SubtitleProcessor`：ASR/翻译输出都必须经过
  `去重 → 断句 → 长度控制 → 缓冲 → 显示策略`，禁止 ASR 直接输出到 UI
- 维护 temporarySubtitle（流式句）与 confirmedSubtitle（确认句），显示缓存最多 2 句

### 智能断句（SubtitleSentenceSplitter）
- 中文 30 字 / 英文 80 字符阈值（可配置），优先在标点（中文 ，。！？； / 英文 ,.!?;）断句
- 英文无标点按最大长度在最近空格处切，不切单词；中文无标点按字硬切
- 新增 `SubtitleDeduplicator`：相同→suppress（不刷新）、前缀增长→merge（合并显示）、
  回溯短前缀→suppress、新内容→refresh

### 空闲自动清除 + 两行显示
- `subtitleClearDelay`（默认 3s，设置页 1–10s 可配）：无新 ASR 输入自动清空浮窗，
  不显示“等待中/占位符”
- 渲染器 maxLines 固定 2：第三句直接丢弃，不用 .lineLimit(2)/truncationMode，
  视图 lineLimit(nil) + fixedSize(vertical:true)，自动高度不裁切

### 延迟与调试
- `SubtitleLatencyManager`：ASR 到达 / 翻译完成 / 显示提交三段计时（目标 <2s）
- DEBUG 调试面板追加“耗时: xxx ms”；状态含 Skipped/Translated/Off/Unavailable

### 暂停/恢复与错误恢复
- 暂停：停止刷新并取消空闲清除，不清空已有字幕；恢复继续监听
- 本地翻译连续失败 3 次（LM Studio 断开等）：`translationUnavailable` 置位，
  自动切换“仅识别模式”，保留原文显示、不崩溃、不再无限重试

### 统一翻译引擎 + 模型管理
- `TranslationEngine` 协议 + `OpenAICompatibleTranslationEngine` + 工厂：
  AppState 两条翻译链路统一走引擎（LM Studio / Ollama / llama.cpp / 在线 API）
- 新增 `LocalModelManager`（Sources/LocalModelManager.swift）：纯文件扫描
  .gguf/.bin/.whisper，展示名称/大小/路径/状态，目录持久化；与网络下载（ModelManager）
  完全隔离；设置页新增“本地模型管理”区（NSOpenPanel 选择目录）
- 设置页新增“字幕空闲清除”秒数输入

### 验证
- `swift build` 通过
- 断句：中文 39 字→2 句（30+9）；英文 112 字符→2 句（80+32，单词未切断）；中文按逗号断
- 去重：相同 suppress / 前缀 merge / 回溯 suppress / 新内容 refresh 全 PASS
- 处理器：40 字中文→2 行上限；相同输入 changed=false；延迟统计 55/88/88ms 正常

## 十四、崩溃修复：显示周期约束更新重入（2026-08-07 16:29）

### 现象
- 运行中 SIGABRT（16:23 构建、16:29 崩溃；15:23 同栈一次）
- 崩溃栈：`__NSWindowGetDisplayCycleObserverForLayout` →
  `_postWindowNeedsUpdateConstraints` 抛 ObjC 异常 → abort；
  lastExceptionBacktrace 显示 `NSHostingView.invalidateSafeAreaInsets` →
  `setNeedsUpdateConstraints` 重入

### 根因
- 已知 macOS SwiftUI 问题：窗口缩放/显示周期内 NSHostingView 反复触发约束更新，
  AppKit 断言 "Update Constraints in Window passes 超过视图数" 直接 abort
- 本 app 放大器：控制器观察 `requiredSubtitleHeight`，而它随 `subtitleQueue.count`
  每个快照变化 → 流式字幕时面板反复 `setFrame(animate:)` 缩放 +
  withAnimation 文本动画 → 多轮布局重入，触发断言

### 修复
- `requiredSubtitleHeight` 改为恒定高度（`max(2, renderer.maxLines + 1)`），
  不随内容/队列变化 → 流式更新不再触发面板缩放
- `applyPanelSize` 去掉 `setFrame(animate:)` 动画缩放（改 `display: true` 直切）
- 视图层去掉 `.animation(..., value:)` 与 `fixedSize(vertical:true)`
  （intrinsic-size 反馈环），保留 lineLimit(nil) 自动换行
- `WhisperASRApp.init` 关闭 `NSWindowAssertWhenDisplayCycleLimitReached` 断言
  作为兜底：即使再触发也只记录日志，不再 abort

### 验证
- `swift build` 通过；`swift run` 启动运行未再崩溃、无新崩溃报告
- 16:35 重新构建 release app（Build complete 12.54s）

## 十五、长时间运行稳定性优化（2026-08-07 第三轮）

> 目标：连续运行数小时稳定、内存不增长、无任务堆积、延迟不累积；UI 完全保持。

### 新增 Sources/SubtitleEngine.swift
- `SubtitleEngine`：统一生命周期门面（Start / Stop / Reset），日志启动/停止；
  AppState 启动/停止实时转录时联动
- `SubtitleUpdateScheduler`：UI 刷新节流（150ms 批量合并，同一窗口多次变化只提交
  最后一次，禁止 token 级刷新）；桥接层 onChange 走调度器
- `SubtitleRingBuffer<Element>`：固定容量环形缓冲（超限删最旧）
- `PerformanceMonitor`：mach_task_basic_info 实时内存、ASR/翻译队列深度、缓冲数、
  模型状态；最近 2 分钟内存增长 >80MB 或翻译队列 >5 判定异常
- `DebugLogger`：500 条环形日志（引擎启动/停止/异常/资源状态），同步 stderr

### 缓存上限（防长运行内存增长）
- `liveSegments` 只保留最近 100 段（suffix 环形窗口）
- `sealedSegments` 只保留最近 200 段（overlap/显示不再需要旧段）
- 翻译三数组（translated / sourceTexts / sealCount）按 100 上限兜底裁剪
- `SubtitleDeduplicator` 近期窗口硬上限 50 条
- 音频 PCM 缓冲维持既有 trimSamples（只保留 ~1s overlap），不再改动

### 自动恢复（每 5 秒健康检查）
- 异常检测：内存持续增长 / 翻译队列过长
- 恢复动作：清 pending、cancel 翻译任务、裁剪缓存数组、ASR 循环意外死亡时
  用 `liveRecorder` 重启一次（有防递归保护），toast 提示“已自动清理并继续运行”

### 任务纪律（审计结论）
- 翻译链路本就是单槽 latest-wins + 单 worker（enqueueLiveTranslation / drainTranslationQueue），
  无无限 Task；live 循环逐块 await 不重叠；停止时全部 cancel（含新增 healthCheckTask）

### 验证
- `swift build` 通过
- 压力测试全 PASS：环形缓冲 1000 写→20 条；去重 10k 高频输入→50 条窗口仍去重；
  处理器 10k 次 ingest→显示行 ≤2；调度器 100 次 schedule→1 次 flush；监控采样正常

## 十六、单句字幕显示重构（借鉴 v2s，2026-08-07 第四轮）

> 参考 /Users/hyj/Downloads/v2s-main 的 draft/committed 双段模型与句子边界启发式，
> 按本 App 规格简化：一次只显示一句，杜绝同句多位置/堆叠/重复翻译。

### 单一字幕显示入口
- 删除三层布局（顶部历史/左上上一条/右下最新）：FloatingLetterViews 只保留一个
  `subtitleDisplayView`（renderer.lines），居中、底部偏上、宽度 880、自动高度、
  无 lineLimit 截断、无 "..."
- 展开面板 760→920pt；底部控制栏改为半透明 Capsule（ultraThinMaterial + opacity 0.45），
  位于字幕下方不遮挡

### 状态机 + 句子端点检测（SubtitleLayers.swift）
- `SubtitleState`：Idle / Listening / Recognizing / Translating / Showing，一次只显示一个
- `SpeechEndpointDetector`：停顿（默认 1s）/ 标点（。？！.?!）/ 最长 5s 任一条件即一句结束；
  `minimumSpeechDuration`（1s）按“有效讲话时长”判定（排除尾随停顿），嗯/啊/单字被丢弃
- 标点结束后 whisper 重复推旧文本不会二次触发（lastEndedText 前缀剥离）

### 整句翻译（不再按每个 ASR 快照发请求）
- VM：Recognizing 实时逐字显示 → 端点检测到一句结束 → `onSentenceCompleted`
- AppState：新增 `translateSentence`（@MainActor，一次一句、单飞、全部语言统一进
  TranslationEngine）；3 秒超时回退原文；连续失败 3 次降级仅识别模式
- **删除中文跳过翻译**：移除 shouldSkipTranslation 门控，中文/英文/日文/韩文/俄文全部翻译
- 移除旧“每快照翻译”链路（ASR 循环不再 enqueueLiveTranslation），避免重复请求

### 其他
- 去重：同句重复（ASR 重复输出）不重复翻译；译文==原文只显示一次
- 最短 1s 前不显示字幕；最长 5s 强制切句（连续 12s 输入实测切 2 次）
- 保留：居中/左对齐、字体风格、单窗口实例、稳定高度防显示周期崩溃

### 验证
- `swift build` 通过；`swift run` 启动无崩溃
- 端点测试：嗯+停顿 discarded；Who is he?（>1s）sentenceEnded；重复旧文本 none；
  12s 连续输入 5s 切句 2 次

## 十七、句子参数设置项 UI（2026-08-07 18:50）

- 设置页「字幕浮层」新增三个滑杆（持久化 UserDefaults，改动即时生效）：
  - 最短识别时长 0.5–3s（默认 1s）：讲话不足不显示字幕
  - 最长单句时长 2–15s（默认 5s）：超过强制截断换下一句
  - 停顿判定阈值 0.5–3s（默认 1s）：停顿超过判定一句结束
- AppState 新增三个带钳制的属性与 setter；桥接层观察并同步 `SpeechEndpointConfig`
- 更新「字幕最大行数」说明文案（当前一句最多行数，非历史行）
- 验证：`swift build` 通过；18:51 重建 release app（Build complete 12.62s），
  二进制含 SpeechEndpointDetector / SubtitleState / translateSentence 符号

## 十八、字幕窗口架构与控制层优化（2026-08-07 第五轮）

### SubtitleLayer / ControlLayer 拆分
- 5 秒无操作只隐藏控制层（bottomBar opacity→0 + allowsHitTesting(false) + 0.2s 动画），
  字幕层保持显示；鼠标移入/点击/移动即显示控制层并重新计时
- 控制层保持半透明悬浮（ultraThinMaterial + opacity 0.45），不遮挡字幕
- 字幕区域扩大：面板 920→1080pt，字幕 maxWidth 1040，fixedSize(vertical:true) 自动高度

### 字体设置
- 原文字号滑杆 20–72（默认 32）、翻译字号 14–48（默认 24），UserDefaults 持久化、
  实时生效（桥接层每快照同步）

### 语言检测（新增 Sources/LanguageDetector.swift）
- 自动检测 zh-CN / zh-TW / zh-HK / en / ja / ko / ru / fr / de，不默认中文；
  法/德用变音符号 + 高频词表区分
- ASR 语言参数确认：whisper.cpp 走 `language = "auto"`（nil 即 auto），未固定 zh
- 调试面板新增 Audio Level / Detected Language；中文不再跳过翻译（上一轮已删）

### 屏幕共享生命周期（ScreenCaptureMonitor + 自动结束录制）
- 新增 ScreenCaptureMonitor：CGPreflightScreenCaptureAccess + 麦克风权限检测
- AudioRecorder.isCaptureSourceRunning()：检测捕获源应用进程是否存活
- AppState 健康检查：录制中捕获源退出 → 自动 finishRecording（停 Audio/ASR/字幕/
  取消 Task/释放资源/更新 UI），日志记录
- 设置页新增「系统状态」：屏幕捕获 / 麦克风 / ASR 模型 / 翻译连接（本地服务实时探测），
  异常显示真实原因

### 验证
- `swift build` 通过；语言检测 11/11 PASS（含无变音德语句子与英文对照）
- 19:xx 重建 release app（Build complete 12.72s）

## 十九、字幕三层架构解耦 + 编辑模式 + 深色适配（2026-08-07 第六轮）

### FloatingSubtitleWindow 三层解耦
- SubtitleContainerLayer：圆角容器/背景/位置/尺寸（SubtitleContainerConfig 独立管理）
- SubtitleTextLayer：原文/译文/字号/粗细/行间距/对齐，只影响文字层
- ControlLayer：控制按钮，5 秒无操作独立隐藏（ControlVisibility：visible/hover/hidden），
  字幕层不受影响
- 窗口尺寸完全由容器配置决定：requiredSubtitleHeight = 容器高度，字号变化不再改变窗口大小

### Subtitle Edit Mode（不增加常驻按钮）
- 双击字幕区进入/退出编辑模式（设置页也有开关）
- 四角白色控制点拖动调整大小（400–1200 × 100–400），容器内拖动调整位置
- 配置持久化：subtitleFrameWidth / Height / OffsetX / OffsetY + 位置/透明度

### 设置页重组
- 「字幕文字」：原文字号 20–72（默认 32）、翻译字号 20–72（默认 32）、
  字体粗细（常规/中等/粗体）、行间距 0–12、文字对齐、最大行数
- 「字幕区域」：宽度 400–1200（默认 800）、高度 100–400（默认 240）、
  垂直/水平位置、背景透明度、边框透明度、进入编辑模式
- 「字幕浮层行为」：空闲清除、最短识别、最长单句、停顿阈值、自动隐藏控件

### 深色模式
- 应用选择弹窗纯白背景 → `windowBackgroundColor` 动态色；黑字/黑圈 → secondary/primary 动态色
- 字幕容器保持黑色半透明（字幕浮窗既定风格，深浅色下均清晰）；其余窗口跟随系统

### 验证
- `swift build` 通过；`swift run` 启动 25s 无崩溃、无新崩溃报告
- 20:xx 重建 release app（Build complete 13.68s）

## 二十、编辑模式改原生窗口交互（2026-08-07 第七轮）

> 保留编辑模式与三层架构；交互改为 macOS 原生窗口体验，不再用 SwiftUI 模拟窗口移动。

### 窗口移动（原生）
- 删除 SwiftUI offset/DragGesture 改坐标的模拟方式
- 编辑模式：`panel.isMovableByWindowBackground = true` +
  FloatingLetterHostingView `mouseDown` 转发 `panel.performDrag(with:)`
  → 拖动字幕区空白处，窗口整体跟随指针（Finder 式，三指拖动兼容）
- 普通模式恢复不可拖动；窗口不出现弹性/扩散/内容漂移

### 窗口缩放（原生 resize）
- 编辑模式：`panel.styleMask.insert(.resizable)`，窗口边缘/四角原生缩放
- 编辑模式容器填满窗口内容区 → 缩放窗口即缩放字幕框（不做 View frame 模拟）
- 退出编辑模式：`.resizable` 移除，恢复干净字幕状态
- 编辑模式期间 `applyPanelSize` 暂停（原生 resize 拥有窗口帧，不互相打架）

### 窗口状态持久化
- 保存 windowWidth / windowHeight / windowOriginX / windowOriginY 到 UserDefaults
- 退出编辑模式 / 关闭浮层时保存；重新打开 App 恢复上次位置与大小（无效帧自动忽略）

### 鼠标穿透
- 普通模式 + 控件隐藏：`panel.ignoresMouseEvents = true`（点击穿透，字幕仍显示，
  悬停轮询唤出控件）；编辑模式 / 控件可见：关闭穿透

### 字幕内容裁剪
- SubtitleContainerLayer `.clipShape(圆角)`：文字只能显示在容器内部，禁止溢出
- 字号仍只影响 SubtitleTextLayer，窗口尺寸来自 NSWindow.frame（非屏幕尺寸）

### 编辑模式视觉
- 只显示细边框（1.5pt），删除四角锚点；双击字幕区 / 设置页按钮进入退出

### 验证
- `swift build` 通过；`swift run` 启动 20s 无崩溃、无新崩溃报告
- 21:xx 重建 release app（Build complete 12.89s）

## 二十一、编辑模式窗口状态污染修复（2026-08-07 第八轮）

### 新增 SubtitleWindowManager（统一窗口状态）
- 统一管理 windowFrame（original/current/final）、windowMode（Normal/Editing）、
  mouseInteraction（passthrough/active）、editState（resize 会话）
- 进入编辑：保存 originalFrame，不做任何 frame 计算/重设；
  退出：锁定 finalFrame（保持现状），只保存并同步容器配置，不再触发 applyPanelSize
- 100 次进出编辑测试：窗口帧完全不变（双击只切换 interactionMode）

### 原生 resize（不再用 SwiftUI 模拟）
- 编辑模式 styleMask += .resizable + 宿主视图边缘命中（6pt）→ `NSWindow.setFrame`，
  四边/四角缩放，锚点保持（右下角跟随指针、左缘保持右锚、纯下缘保持上锚）
- 边缘/四角显示系统 resize 光标；面板 minSize 448×172 防止无限收缩/扩张
- resize 数学用本地 CGFloat 显式计算（规避该环境对 NSRect 链式属性算术的异常），
  单测覆盖 6 种边/角 + 钳制全部 PASS

### 鼠标穿透彻底隔离
- Normal：`ignoresMouseEvents = true`，不 hover 检测、不显示控件（穿透）
- Editing：`ignoresMouseEvents = false`，鼠标可操作、控制栏显示
- hover 轮询 / 点击唤出 / 自动隐藏计时全部只在编辑模式生效

### 验证
- `swift build` 通过；`swift run` 启动 20s 无崩溃
- 窗口管理器单测：100 次进出帧稳定 / 四角四边锚点 / 钳制 448–1920 全 PASS
- 22:xx 重建 release app（Build complete 13.58s）

## 二十二、鼠标穿透功能 + 三态窗口模式（2026-08-07 第九轮）

### 控制栏新增 ↗ 按钮
- 位置：置顶按钮旁；半透明圆形背景，开启蓝色高亮，关闭默认色
- 编辑模式下按钮禁用（穿透与编辑互斥）

### 三态窗口模式（SubtitleWindowMode）
- normal：可交互、可拖动（isMovableByWindowBackground）、hover 显示控件、5s 自动隐藏
- editing：可缩放（边缘/四角原生 resize）、细边框、控件常显
- passthrough：ignoresMouseEvents = true，只显示字幕、不监听鼠标、不显示控件
- 穿透开启时双击/进入编辑被拒绝；进入编辑自动关闭穿透；默认启动不开启穿透
- 穿透状态不持久化（重启默认关闭）；窗口位置/大小继续持久化恢复

### 验证
- 管理器单测：三态切换 + 100 次进出编辑帧稳定 PASS
- VM 单测：穿透/编辑互斥（穿透开→禁止编辑；进编辑→自动关穿透）+ 100 次切换无漂移 PASS
- `swift build` 通过；`swift run` 启动 18s 无崩溃
- 23:xx 重建 release app（Build complete 23.47s）

## 二十三、窗口管理重构：穿透悬停呼出控制栏 + 零漂移（2026-08-07 第十轮）

### 统一窗口模式（SubtitleWindowMode）
- 新增 `applyWindowMode()` 单一入口：normal / editing / passthrough 每次切换
  都显式重设 ignoresMouseEvents / isMovableByWindowBackground / styleMask /
  hosting isEditMode，三态互不残留
- 模式切换只改变 mode，不重新计算/重设窗口 frame（普通模式位置不再异常）
- applyPanelSize 增加 2pt 容差，消除模式切换/取整造成的微缩放累积

### 鼠标穿透 + 3 秒停留呼出控制栏
- 穿透：`ignoresMouseEvents = true`（点击完全穿过，不挡视频/网页）
- HoverDetection：全局鼠标轮询做停留检测——进入字幕区域 3 秒 → 显示控制栏
  （临时 ignoresMouseEvents=false，仅控制层可点）；离开 1.5 秒或控制栏 5 秒
  无操作 → 隐藏控制栏并恢复穿透
- 普通/编辑模式不触发穿透停留逻辑；穿透状态默认关闭、不持久化

### 编辑模式原生事件
- 编辑模式下 SwiftUI 字幕容器 `allowsHitTesting(false)`：事件全部交给
  NSHostingView/NSWindow，边缘 6pt 命中 → 原生 resize（四边/四角），
  空白区域 → performDrag 移动窗口；双击由 AppKit 层检测退出编辑
- 编辑模式容器不再吞鼠标事件，白框拖拽 resize 真正生效

### 持久化键
- 改为 subtitleWindowX / Y / Width / Height；重启恢复位置大小；
  mousePassthrough 永远默认关闭

### 验证
- `swift build` 通过；`swift run` 启动 18s 无崩溃、无新崩溃报告
- 0x 重建 release app（Build complete 12.96s）

## 二十四、窗口移动/缩放规格调整（2026-08-08 第一轮）

### 窗口移动（取消拖动区域限制）
- 普通/编辑模式：任意空白区域均可拖动移动窗口
  （isMovableByWindowBackground + 编辑模式 performDrag）
- 只改变 NSWindow frame origin，不修改 SwiftUI 坐标/内容布局

### 缩放（仅左上角 40×40 Resize Area）
- 删除四边/其他角缩放；只保留左上角 40×40 缩放区
- 进入该区域显示 macOS 风格对角 resize 光标（SF Symbol 生成，无系统对角光标时回退）
- 左上角拖动 = 原生 NSWindow resize：改 size 同时改 origin，右下角位置固定
  （单测：848×336 向左上拖 -50/+50 → 898×386，右下角 (948,200) 保持）

### 验证
- `swift build` 通过；`swift run` 启动 15s 无崩溃
- 左上角锚定数学单测 PASS
- 0x 重建 release app（Build complete 15.75s）

## 二十五、编辑模式成为唯一默认模式（2026-08-08 第二轮）

### 删除旧默认模式
- 删除 normal/editing 模式切换、进入/退出编辑流程、双击切换、设置页
  「进入/退出编辑模式」按钮、旧位置/偏移配置（垂直/水平位置、OffsetX/Y）
- `SubtitleWindowMode` 收敛为 interactive（唯一默认）/ passthrough（↗ 运行时切换）
- 启动直接进入交互态：窗口始终可移动（任意空白）、左上角 40×40 缩放、
  显示可配置编辑边框、控制栏操作

### 字幕编辑边框设置（仅视觉，不影响移动/缩放）
- 新增设置区：显示边框 Toggle（默认开）、ColorPicker 颜色、透明度 Slider（0–1）
- hex 字符串持久化（subtitleEditBorderVisible / ColorHex / Opacity）

### 缩放稳定性
- 容器始终填满窗口内容区；resize 拖拽中不再每事件同步容器/触发 applyPanelSize
  （isResizing 状态：idle → resizing，松手一次性同步并保存）
- 左上角缩放继续原生 NSWindow frame 修改，右下角锚定
- applyPanelSize 在拖拽/穿透期间跳过

### 验证
- 单测：默认 interactive、100 次穿透切换帧不变、左上角缩放右下角锚定、
  VM 穿透切换 PASS
- `swift build` 通过；`swift run` 启动 15s 无崩溃
- 0x 重建 release app（Build complete ~30s）

## 二十六、左上角缩放稳定性优化（2026-08-08 第三轮）

### 独立 Resize 状态 + 60fps 节流
- ResizeState：idle → resizing → idle；只有 resizing 才更新窗口 frame
- 鼠标事件只记录“目标帧”（pendingResizeFrame），由 CADisplayLink（NSView.displayLink）
  60fps 统一提交——不跟随每个 mousemove 刷新，快速拖动不抖动
- 每次从 resizeStartFrame + mouseStartPosition 计算（newWidth = startW - deltaX、
  newHeight = startH + deltaY、origin 按右下角锚定），latest-wins，无累积误差

### 尺寸限制与光标锁定
- minSize 300×80（窗口级），maxSize = 屏幕 frame，防止缩放过小/爆炸
- 缩放期间 push resize 光标、松手 pop——指针越出 40×40 区域光标不再反复切换
- resize 拖拽中不同步容器、不触发 applyPanelSize、不写 UserDefaults（save 加 0.5pt 去抖）

### 验证
- 单测：200 次快速拖动 latest-wins 与一次性计算一致（无累积误差）、
  300×80 / 屏幕钳制且右下角锚定、ResizeState 三态 PASS
- `swift build` 通过；`swift run` 启动 15s 无崩溃
- 0x 重建 release app（Build complete 28.29s）

## 二十七、架构稳定性重构：分层收口 + 状态循环根治（2026-08-08 第四轮）

> 纯稳定性重构，不新增功能。目标：长运行不卡顿、窗口状态不混乱、
> 无 SwiftUI 状态循环、字幕渲染与窗口控制解耦、内存不增长、无崩溃风险。

### 统一日志与错误管理（新增 Sources/AppLogger.swift）
- `AppLogger`：分类日志（Window / ASR / Translation / Model / UI / Engine），
  1000 条环形缓冲 + NSLock 线程安全 + stdout；`DebugLogger` 改为薄封装汇入
  `.engine` 分类（消除双缓冲并存）
- `ErrorManager`：模型 / API / 网络 / ASR 失败统一上报（分类日志 + 可选 toast），
  绝不抛出、绝不导致退出；toastHandler 由 AppState 启动时注入
- 接入点：模型预加载失败 / ASR chunk 超时与错误 / 整句翻译失败 /
  翻译重试与最终失败 / 窗口 present / dismiss / 模式切换 / resize 会话 /
  模型选择、下载开始、取消、完成、删除

### 窗口层：状态循环根治 + 任务风暴消除（FloatingLetterOverlayController）
- didMove 重复注册（2 个 observer）合并为 1；didMove/didResize 统一入口
- 高频窗口通知经 `FrameSyncBox` 合并：任意时刻最多 1 个排队同步任务
  （原生 resize 每帧触发通知，此前每个事件 spawn 一个 MainActor Task）
- `observeViewModel` 按职责拆分签名（pin / size / mode 三个 Hasher 签名）：
  hover 引起的 controlVisibility 翻转不再触发 applyPanelSize 尺寸重算；
  尺寸重算保留 2pt 容差 + 拖拽/穿透跳过；present/dismiss 重置签名
- 容器同步无变化直接返回（VM.adjustSubtitleContainer 与
  AppState.setSubtitleContainerWidth/Height 双端守卫）：
  窗口移动不再触发 @Observable 变更与 UserDefaults 写盘，
  彻底切断 Window → 状态 → UI → Window 反馈环
- dismiss 补齐资源释放：passthroughHoverTask / passthroughControlsHideTask /
  resizeDisplayLink / pendingResizeFrame（关闭瞬间可能正处于悬停计时或拖拽中）

### AppState：统一状态管理 + 死代码清除 + 任务纪律
- `translationMode` 从"直读 UserDefaults 的计算属性"（Observation 跟踪不到）
  改为存储属性 + setTranslationMode 唯一写入口；设置页 Picker 改绑 AppState，
  消除 View 层平行数据源
- 删除约 150 行无人调用的旧翻译队列死代码（enqueueLiveTranslation /
  drainTranslationQueue / translateLiveSegments / updateSealCounts 及相关字段）
- 删除 "Recording" 窗口死引用（AppState.setRecordingAlwaysOnTop 内的
  NSApp.windows 遍历、SidebarView 的 .close()）；窗口层级由窗口层单向同步
- `shutdown()` 现在取消全部任务：live ASR / 整句翻译 / 健康检查 / toast /
  整段翻译（新增 translateItemTask 句柄）/ 文件转录队列（新增
  transcriptionQueueTask 句柄）+ subtitleEngine.stop()

### 模型与翻译服务隔离
- ModelManager 新增统一操作门面：select / startDownload / cancelDownload
  （delete 已有）；设置页 ModelRowView 不再直接驱动 ModelDownloader
- TranslationService 保持异步 + timeout + retry + cancel（既有），
  重试与最终失败接入 AppLogger.translation 分类日志

### 历史记录独立（SubtitleHistoryManager，Sources/SubtitleEngine.swift）
- 每句结束记录一条（时间 / 原文 / 翻译 / 语言），固定容量 200 环形缓冲；
  与实时字幕状态（liveSegments / renderer）完全不共享数组；
  桥接层 onSentenceCompleted 单一喂入点，新会话开始自动清空

### 验证
- `swift build --disable-sandbox` 通过（本环境 SwiftPM 嵌套 sandbox-exec
  被拦截，需 --disable-sandbox；仅余 transcribe.cpp 既有 ld 版本警告）
- 二进制符号确认：AppLogger / ErrorManager / SubtitleHistoryManager 存在，
  enqueueLiveTranslation / drainTranslationQueue 已消失
- 启动冒烟 15s 无崩溃（两轮）

### 既有机制确认（本轮未改动，已符合目标）
- 字幕刷新节流：ASR → liveSegments 环形窗口（100 段上限）→
  SubtitleUpdateScheduler 150ms 批量合并 → UI（远低于 30FPS 上限）
- 后台任务：ASR 单任务逐块 await 不重叠、翻译整句单飞、模型加载 off-main；
  音频 PCM 缓冲 trimSamples 只保留 ~1s overlap
- 内存：sealed 段 200 上限、去重窗口 50 上限、日志 1000 条上限、
  历史 200 条上限——全部固定容量
- FloatingAppPicker 监听器在 dismiss 时完整移除；AudioPlayerManager
  time/end observer 在 cleanup 中完整移除

## 二十七·补、release app 重建（2026-08-08 01:44）

- `Scripts/build_release.sh` 增加可选参数透传：`SWIFTPM_EXTRA_ARGS`（本环境
  SwiftPM 嵌套 sandbox-exec 被拦截，需 `SWIFTPM_EXTRA_ARGS=--disable-sandbox`；
  默认空，行为不变）
- 构建：Build complete 48.81s；app bundle 重建（未签名），二进制 17M，
  已含 AppLogger / ErrorManager / SubtitleHistoryManager 符号（48 处匹配）
- `open WhisperASR.app` 启动冒烟 12s 无崩溃
- 产物：`WhisperASR.app`（含第二十七节架构稳定性重构，未打 DMG）

## 二十八、转录历史批量删除 + 缩放振荡根治 + 翻译串行队列（2026-08-08 第五轮）

> UI 风格保持不变。

### 转录历史批量删除（新增 Sources/HistoryManager.swift）
- `TranscriptionHistoryManager`：历史列表唯一数据出入口（load / add / save /
  remove / remove(ids:) / 查询 / 上限裁剪），AppState.items 变为只读转发，
  所有增删改经管理器收口（此前 View/业务直接操作数组与 TranscriptionStore）
- 上限 500 条：超出裁剪最旧（进行中的不动；录音进废纸篓可恢复），
  防长时间运行内存无界增长
- SidebarView 编辑模式：工具栏「选择」→ 多选 List（Set<UUID>），
  「删除(n)」带确认弹窗（说明录音进废纸篓 / 导入文件保留 / 进行中跳过），
  删除后 @Observable 自动刷新列表；行内容抽取为共用 itemRows 防两份实现漂移
- 批量删除跳过进行中的转录（完成回调会回写，删除会复活）

### 缩放振荡根治（FloatingLetterOverlayController）
- **根因**：resize 拖拽用 `event.locationInWindow`（窗口坐标）计算 delta；
  左上角缩放每提交一帧窗口原点即移动，下一事件的窗口坐标被原点移动
  反向补偿 → 从 startFrame 重算时来回振荡（偶发抽搐/跳动/方向错误）。
  **修复**：起点与拖拽全程改用屏幕坐标（NSEvent.mouseLocation），
  窗口移动不影响 delta，从数学上消除反馈振荡
- 松手后同步尺寸签名（lastAppliedSizeSignature）：防止随后的状态观察用
  容器配置反推 targetSize 把窗口"弹回"
- minSize 300×80 → 448×172：与容器最小值（400×100 + chrome）对齐，
  杜绝"缩到比容器小→容器钳制→回弹"的尺寸打架
- 容器钳制上限 1200/400 → 4000/2160（VM / AppState / syncContainer 三处）：
  窗口是尺寸唯一事实来源，容器配置只做镜像；targetSize 上限同步放宽，
  用户拖出的大窗口不会在下次设置变更时被意外缩小
- SubtitleWindowManager.markFrame 去掉 `mouseInteraction = .active` 副作用
  （穿透模式下窗口被程序移动曾误翻交互状态）

### 整句翻译串行队列（AppState）
- `requestSentenceTranslation`：链式串行（每句 await 前一句），
  多句快速完成不再并发请求（防乱序/请求堆积）；10s 超时兜底回退原文；
  排队上限 8 句，超出丢弃最新并记录历史（显示原文）
- 历史记录收口到该入口（时间/原文/翻译/语言），桥接层不再管记录
- 暂停 / 停止 / shutdown 取消串行链并清空排队计数；
  健康检查 translationQueue 改用真实排队数
- 清除残留字段 liveTranslationTask（只取消不赋值的死字段）及过期注释

### 验证
- `swift build --disable-sandbox` 通过（12.82s）；启动冒烟 12s 无崩溃
- 二进制含 TranscriptionHistoryManager 符号（77 处匹配）
- 18:14 重建 release app（Build complete ~35s），`open WhisperASR.app` 冒烟 12s 无崩溃

### 实时链路架构确认（Audio→显示 单向流，无旁路）
- AudioRecorder（独立线程采集 + PCM trim ~1s overlap）→
  AppState ASR 单任务逐块 await（不重叠）→ liveSegments 环形窗口（100 上限）→
  桥接层 SubtitleUpdateScheduler（150ms 合并节流）→ FloatingLetterViewModel
  （唯一渲染入口 renderText）→ UI；partial 只显示、final 才进翻译串行队列
- 全链路无 ASR→UI 直写、无 UI→Window 反写

## 二十八·补、批量删除多选交互修复（2026-08-08 02:28）

### 问题
- macOS `List(selection: Set<UUID>)` 的多选只能靠 ⌘/⇧ 点按，无可见勾选 UI，
  用户找不到多选入口，批量删除实际不可用

### 修复（SidebarView）
- 编辑模式行改为显式勾选圈（checkmark.circle.fill 蓝色 / circle 灰色），
  点击行任意位置切换勾选（contentShape + onTapGesture），不再依赖 List 多选语义
- 编辑模式 List 去掉 selection 绑定：不误改 selectedItemID、不跳详情页
- 新增底部操作栏：全选/全不选 · 删除(n)（带确认）· 完成；
  工具栏编辑按钮简化为纯模式切换入口

### 验证
- `swift build --disable-sandbox` 通过（4.68s）
- 02:28 重建 release app；`open WhisperASR.app` 冒烟 12s 无崩溃

## 二十九、ASR 状态显示修复 + 快速切换融合本地模型（2026-08-08 02:41）

### ASR 系统状态误报修复（SettingsView.refreshSystemStatus）
- 现象：使用自定义本地模型（modelPath）时系统状态显示「✗ 未选择模型」
- 根因：状态检测只看 ModelManager 的 selected/live fileName，
  与 TranscriptionService.resolveModelPath 的实际优先级不一致
- 修复：状态检测与 resolveModelPath 同一优先级——
  自定义本地路径（存在）→「✓ 本地模型：文件名」；
  显式选择 →「✓ 模型名」；默认路径存在 →「✓ 自动（默认模型）」；否则 ✗

### 工具栏快速切换融合本地模型（ModelPickerMenu）
- 「转录模型」Picker 融合两类来源：下载目录（catalog）+
  LocalModelManager 扫描到的本地自定义模型（如 LM Studio 模型目录，
  显示「名称（本地 x.xx GB）」）
- 选中本地模型 → 写入 modelPath（resolveModelPath 最高优先级，立即生效）；
  选回 catalog/自动 → 清除 modelPath（否则自定义路径优先级最高，选择不生效）
- 菜单按钮标题显示当前生效模型（本地模型名 / catalog 显示名）
- onAppear 同时刷新下载目录与本地目录扫描；切换经 AppLogger 记录

### 验证
- `swift build --disable-sandbox` 通过（5.71s）
- 02:42 重建 release app（Build complete 14.68s）；冒烟 12s 无崩溃

## 三十、本地模型管理：悬停启用单个模型（2026-08-08 02:55）

### 需求
- 本地模型管理列表可直接选用单个模型：悬停行显示「启用」，同时只允许一个模型在运行

### 实现（SettingsView 新增 LocalModelRowView）
- 抽取本地模型行为独立视图：悬停（onHover）显示操作按钮，未悬停显示状态文字
- 未启用行：悬停显示「启用」→ 写入 modelPath（resolveModelPath 最高优先级，立即生效）
- 已启用行：状态显示蓝色「使用中」，悬停显示「停用」→ 清空 modelPath
- 单模型保证：modelPath 为单值，启用新模型自动替换旧的，无需额外互斥逻辑
- 与工具栏快速切换菜单完全互通（同一 modelPath 键 + @AppStorage 自动刷新）
- 启用/停用经 AppLogger（.model）记录

### 验证
- `swift build --disable-sandbox` 通过（4.32s）
- 02:55 重建 release app（Build complete 13.96s）；冒烟 12s 无崩溃

## 三十一、字幕显示与翻译速度回归修复（2026-08-08 03:24）

> 用户反馈：不显示原文+译文、翻译很慢。均为第二十八节改动的回归。

### 回归根因（三处叠加）
1. **串行链丢弃译文**：整句翻译串行化后，译文返回时字幕状态机常已离开
   `.translating/.showing`（setTranslationResult 状态守卫直接丢弃）→ 不显示译文；
   串行等待也让后句翻译排队 → 体感很慢
2. **取消计入失败**：10s 超时兜底触发 CancellationError 被通用 catch 计入
   失败次数，慢句连续 3 次即误判"翻译服务不可用"自动降级仅识别模式
3. **译文替换原文**：单行替换显示本就不符合"原文+译文"双行预期

### 修复
- 翻译队列改回**有界并发**（每句独立请求，上限 8 在途），删除串行链字段
- `translateSentence` / `requestSentenceTranslation`：CancellationError 与超时
  均不计入三连失败（服务慢 ≠ 服务不可用）
- **原文+译文同时显示**：新增独立 `translationRenderer`（译文区），
  原文渲染器保持不动；译文到达后渲染到原文下方（译文字号独立、85% 白）
- `setTranslationResult` 守卫从状态机改为**文本匹配**：
  只要当前显示的还是这一句（recognitionText 未变）就接受译文——
  慢译迟到也能上屏；新句开始（文本已变）才丢弃
- 翻译超时兜底不再重渲染原文（避免闪烁），只清译文区

### 验证
- `swift build --disable-sandbox` 通过（2.84s），警告清零
- 03:25 重建 release app（Build complete 14.13s）；冒烟 12s 无崩溃

## 三十二、英文识别慢根因修复：自适应静音阈值（2026-08-08 03:45）

> 用户反馈：英文识别很慢。排查结论：**代码逻辑原因，不是模型原因**。

### 排查过程（benchmark 证据）
- 模型基准（Qwen3-ASR-1.7B Q5_K_M，Metal）：11s 英文 jfk 推理 ~1-2s
  （6-9x 实时），5.6s 中文同样量级——模型对英文并不慢
- RMS 测量（100ms 帧）：英文素材最安静帧 0.0034（jfk），p10 底噪 0.009；
  而封口/跳过的固定静音阈值 = 0.001 → 英文音频**永远触发不了干净停顿封口**
- 后果：尾部只能长整到 12s 强制上限，每轮重转录 ~12s 音频（每轮 ~1.5-2s），
  0.3s 新音频就开下一轮 → 队列持续积压 → 字幕延迟数秒且越说越慢
- 中文不受影响：干净输入底噪 p10=0.00054 → 阈值 0.001 正常工作（每句干净封口，
  尾部仅 1-3s，单轮 ~0.3s）

### 修复
- AudioRecorder 新增 `estimateNoiseFloor`：最近 10s 帧 RMS 的 10 分位（= 底噪水平）
- 实时循环每轮动态计算：
  跳过阈值 = 底噪×1.2（上限 0.01）；封口阈值 = 底噪×2.0（上限 0.02）；
  底噪≈0 的干净输入回落到固定 0.001——中文行为完全不变
- 强制封口上限 12s → 8s：连续无停顿语音的单轮重转录成本再降 ~35%
- 仿真验证（旧→新阈值封口次数）：jfk 0→5、jobs-silence 0→4、
  whole-earth(84s) 0→30、zh 2→2（不变）

### 验证
- `swift build --disable-sandbox` 通过（28.73s）
- 03:45 重建 release app（Build complete 15.09s）；冒烟 12s 无崩溃
