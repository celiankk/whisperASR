# WhisperASR 开发文档

## 1. 项目概述

WhisperASR 是一个 macOS 本地语音转文字（ASR）应用：

- 系统音频/麦克风录制 + Whisper（whisper.cpp）本地转录
- 文件转录（拖拽 / 文件选择），支持字幕导出（SRT / VTT / SubViewer）
- 实时转录 + 实时翻译（OpenAI 兼容 API）
- 会议纪要生成、本地 OpenAI 兼容转录 API 服务器
- 字幕浮层：录制时把实时字幕显示在置顶悬浮窗中

技术栈：Swift 5.9 / SwiftUI + AppKit（`@Observable` 状态），whisper.cpp（CWhisper.xcframework），
ScreenCaptureKit 屏幕音频捕获，FlyingFox 本地 HTTP 服务。

## 2. 源码结构

| 文件 | 职责 |
|---|---|
| `WhisperASRApp.swift` | App 入口、窗口场景、调试菜单入口 |
| `AppState.swift` | 全局状态：转录项、实时转录/翻译、字幕浮层开关 |
| `RecordingView.swift` | 录制窗口：实时字幕列表 + 操作栏（含浮层开关） |
| `SubtitleOverlay.swift` | 字幕浮层：置顶无边框面板、样式、控制器 |
| `SubtitleBlurText.swift` | 字幕逐字入场动画（BlurText 的 SwiftUI 移植） |
| `DebugSubtitleView.swift` | 调试字幕工具：手动输入文字预览字幕效果 |
| `SettingsView.swift` | 设置（含「字幕浮层」区块） |
| `TranscriptionService.swift` / `AudioRecorder.swift` | 转录引擎与录音 |
| `build_release.sh` / `release.sh` | 打包脚本 |

## 3. 字幕浮层（SubtitleOverlay）

### 行为

- 开启浮层后立即显示（无需录制）：屏幕**顶部居中**的置顶无边框字幕条
- 无实时内容时显示欢迎语「欢迎使用，顶部字幕条已经准备好了。」
- `statusBar` 层级 + `fullScreenAuxiliary`，可盖在全屏窗口上；非激活面板，不抢焦点
- 显示内容：当前实时字幕（原文）+ 翻译（开启实时翻译时）
- 历史文本不参与动画；只有**新出现**的字/词播放入场动画
- 可拖动、右上角关闭、位置自动记忆；面板高度随内容自适应
- 背景黑色 0.32、白色描边 0.08、圆角遵循 Apple 规范

### 设置键（UserDefaults）

| Key | 说明 |
|---|---|
| `subtitleOverlayVisible` | 浮层开关（持久化） |
| `subtitleOverlaySourceFontSize` | 原文字号（pt，滑杆 14–40） |
| `subtitleOverlayTranslationFontSize` | 翻译字号（pt，滑杆 12–32） |
| `subtitleOverlayBorderOpacity` | 边框透明度（0–0.3，滑杆 0–30%） |
| `subtitleOverlayFrame` | 面板位置与尺寸 |

### 圆角规范

Apple 标准窗口圆角：macOS 11–15 为 10pt，macOS 26+（Tahoe）为 26pt。
实现见 `SubtitleOverlayMetrics.cornerRadius`（系统版本自适应）。

## 4. 字幕逐字入场动画（SubtitleBlurText）

移植自 v2s 项目使用的 React `BlurText`（motion/react）：

- 每个词（中文无空格时按字）从 `blur(10px) + opacity 0 + y -50` 入场
- 两段关键帧：`blur 10→5→0`、`opacity 0→0.5→1`、`y -50→5→0`
- 每段时长 `stepDuration = 0.25s`（共 0.5s），段间错峰 `delay = 索引 × 0.12s`
- **增量动画**：组件记录上一段文本，与当前文本做公共前缀对比，
  已显示的字保持静止，只对新追加的字/词播放入场动画
- 换行使用自实现 `SubtitleFlowLayout`（居中、可换行）
- 间距遵循 Apple 规范：词间距 = 字体的空格宽度，中文逐字间距 = 0（字形紧排），
  行高 = 字体 `lineHeight`（行间距 0 附加）

实现要点：

- 每个动画片段（词/字）用 `KeyframeAnimator`（macOS 14+）
- **必须**用 AppKit 精确测量文本尺寸并给动画片段设置固定 `frame`，
  否则带动画的视图会向流式布局上报不可靠的固有尺寸（见第 7 节 Bug 记录）。

## 5. 调试字幕工具（DebugSubtitleView）

无需屏幕录制权限即可预览字幕效果：

- 入口：菜单栏 **调试 → 字幕浮层调试…**
- 输入原文（可选翻译文本）→ 窗口内实时预览逐字动画（译文在上、原文在下）；
  勾选「以浮层显示」→ 显示置顶悬浮层
- 完全独立：不依赖 `AppState`、录制管线或正式浮层

删除方式：

1. 删除 `Sources/DebugSubtitleView.swift`
2. 删除 `WhisperASRApp.swift` 中的 `Window("字幕浮层调试")` 场景和「调试」`CommandMenu`

## 6. 构建与打包

```bash
# 调试运行
swift run

# release .app 打包（含图标生成；无签名证书时跳过签名）
bash Scripts/build_release.sh

# DMG
# 1) 运行 build_release.sh 生成 WhisperASR.app
# 2) 用 hdiutil 打包（见下）
```

```bash
STAGING=$(mktemp -d /tmp/whisperasr-dmg.XXXXXX)
cp -R WhisperASR.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "WhisperASR" -srcfolder "$STAGING" \
  -ov -format UDZO -fs HFS+ "WhisperASR-0.9.0.dmg"
rm -rf "$STAGING"
```

注意：

- 完整签名/公证流程见 `Scripts/release.sh`（需要 Developer ID 证书与 notarytool 配置）
- 未签名 DMG 分发给他人时，首次打开需在「系统设置 → 隐私与安全性」允许
- 本机 CLI 工具链存在 SDK/编译器版本不匹配（Swift 6.3.3 vs SDK 6.3.2），
  `swift build` 需要在可写模块缓存的环境（如 Xcode 或提权）下执行

## 7. Bug 记录

### 7.1 字幕竖向堆叠显示

**现象**：字幕按字/词从上到下逐行堆叠，形成竖长条（每个字符独占一行）。

**根因**：逐字动画使用 `KeyframeAnimator` 包裹文本；带动画的视图向
`SubtitleFlowLayout` 上报的固有尺寸不可靠（偏大/异常），导致流式布局判定
每个字符都无法放入当前行，全部换行 → 竖向堆叠。

**修复**：

- 用 AppKit（`NSString.size(withAttributes:)`）按实际字体精确测量每个片段尺寸
- 给每个动画片段在 `KeyframeAnimator` **外层**设置固定 `frame(width:height:)`
- 布局对非有限宽度提案做防御（`isFinite` 检查）
- 浮层面板内容固定 640pt 宽，防止窗口/内容收缩

**验证**：`swift build` 通过；调试窗口输入文字后字幕横向逐字浮现。

### 7.2 旧实例约束更新崩溃

**现象**：旧构建在窗口约束更新阶段抛 NSException 崩溃。

**处理**：浮层 `NSHostingView` 显式设置 `autoresizingMask`，调试窗口去掉
`.windowResizability(.contentSize)`，布局防御异常尺寸。新构建持续运行正常。

## 8. 版本管理约定

- 开发在 `test` 分支进行，验证后合并到 `main`
- 提交信息建议：`fix: ...` / `feat: ...` / `chore: ...`
- 发布版本号在 `build_release.sh` 的 Info.plist（`CFBundleShortVersionString`）维护
