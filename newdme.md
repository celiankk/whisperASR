# WhisperASR 开发日志（2026-08-06）

> 记录从“一体化字幕浮层重构”到“Qwen3-ASR 本地推理 / 本地 LM 翻译接入”的全部开发操作。

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
