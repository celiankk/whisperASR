import Foundation
import Observation
import SwiftUI

// MARK: - 浮层状态物理隔离（P1 渲染优化：双模型拆分）
//
// 原 FloatingLetterViewModel 是单一 @Observable 巨型对象，高频字幕流与
// 低频工具栏状态混装。Observation 的脏区追踪虽是「属性粒度」，但视图层
// 把两个域的状态读进同一个 body（内联计算属性）时，两个域的变化就会
// 连带同一段 body 重评估——整棵视图树频繁重测量。
//
// 拆分原则（配合 FloatingLetterViews 的子视图封装）：
// - SubtitleStreamModel：**高频**字幕显示状态——每次 ASR 快照/流式译文
//   增量都会写入。只允许字幕渲染区（SubtitleStreamSection）读取。
// - OverlayControlModel：**低频**控制/工具栏状态——用户点击、设置同步、
//   秒级计时器驱动。只允许控制栏（OverlayControlBar）与窗口控制器读取。
//
// 写入方向纪律（防反向污染）：
// - 高频域（stream）绝不写低频域（controls）——字幕刷新永远不脏工具栏；
// - 低频域写高频域仅限用户显式开关（如 subtitleTextVisible）——低频操作
//   连带字幕区一次重评是必要成本，反向则不成立。
//
// FloatingLetterViewModel 保留同名的兼容计算属性委托到两个模型
//（控制器/桥接层既有引用零改动）；注意：@Observable 只对**存储属性**
// 注册追踪，VM 上的委托计算属性不注册 VM 自身——视图经由委托读取时，
// 追踪仍然落在真正的数据源（stream/controls）上，隔离不被破坏。

// MARK: 高频域：字幕流

/// 字幕显示状态（高频）。视图侧只由 SubtitleStreamSection 消费。
@Observable
final class SubtitleStreamModel {
    /// 当前字幕文本（业务层持续推入最新识别结果）。
    var subtitleText = ""
    /// 当前段落的译文（可选）。
    var translationText: String?
    /// 实时识别文本（Recognizing 阶段显示）。
    var recognitionText = ""
    /// 当前显示的是译文（true）还是原文（false）。
    var showingTranslation = false
    /// 字幕状态机：Idle / Listening / Recognizing / Translating / Showing。
    var subtitleState: SubtitleState = .idle
    /// 全 App 唯一的字幕渲染器（禁止多个 TextOverlay）。
    var renderer = SubtitleRenderer(maxLines: 2)
    /// 译文渲染器：与原文并存（原文在上、译文在下同时显示）。
    var translationRenderer = SubtitleRenderer(maxLines: 2)
    /// 最近一次字幕处理链路调试信息（开发模式浮层显示；随快照高频更新）。
    var debugInfo: FloatingLetterViewModel.SubtitleDebugInfo?

    /// 去除首尾空白后的译文；空字符串视为无译文。
    var nonEmptyTranslation: String? {
        guard let text = translationText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return nil }
        return text
    }
}

// MARK: 低频域：控制工具栏

/// 控制层/工具栏状态（低频）。视图侧只由 OverlayControlBar 消费；
/// 窗口控制器按签名读取（isPinned / isCompact / maxLines / 容器配置）。
@Observable
final class OverlayControlModel {
    // MARK: 工具栏开关

    /// 字幕文本是否显示（工具栏「字幕」开关，纯 UI 状态）。
    var subtitleTextVisible = true
    /// 最大显示行数（1–3，默认 2，由设置页同步）。
    var maxLines = 2
    /// 对话气泡：翻译是否暂停。
    var isTranslationPaused = false
    /// 眼睛：是否仅显示译文。
    var translationOnly = false
    /// 图钉：窗口置顶。
    var isPinned = false
    /// 缩放箭头：紧凑/展开模式。
    var isCompact = false
    /// 是否允许闲置自动隐藏（录制中可配置）。
    var autoHideEnabled = true
    /// 鼠标穿透（默认关闭）：开启后窗口 ignoresMouseEvents，只显示字幕。
    var mousePassthrough = false

    /// 控制层可见性状态（ControlVisibilityManager）：
    /// visible / hover = 显示；hidden = 5 秒无操作后隐藏（字幕层不受影响）。
    enum ControlVisibility: Equatable, Hashable {
        case visible
        case hidden
    }

    var controlVisibility: ControlVisibility = .visible

    /// 控制层是否可见（视图层使用；hidden 时隐藏且不响应点击）。
    var controlsVisible: Bool {
        controlVisibility != .hidden
    }

    /// 功能区手动收起（只保留收起按钮，其余控件隐藏）；持久化。
    /// 与自动隐藏独立：5 秒无操作自动隐藏整个功能区，鼠标移入再显示时
    /// 保持收起状态。
    var controlsCollapsed = UserDefaults.standard.bool(forKey: "subtitleControlsCollapsed") {
        didSet { UserDefaults.standard.set(controlsCollapsed, forKey: "subtitleControlsCollapsed") }
    }

    // MARK: 录制状态

    /// 是否正在录制（录制中才展示录制相关控件）。
    var isRecording = false
    /// 监听的软件名称。
    var recordingAppName = "未选择应用"
    /// 格式化后的录制时长（mm:ss；秒级刷新，低频域内消化）。
    var recordingDurationText = "00:00"

    // MARK: 选择应用阶段（「开始录制 → 选择应用 → 字幕浮层」入口）

    /// 应用列表加载阶段。
    enum AppListPhase: Equatable {
        case idle
        case loading
        case ready
        case permissionDenied
        /// 非权限类失败：UI 显示 `appListError` 的真实文案，而不是
        /// 把用户引向系统设置的权限引导。
        case failed
    }

    /// 浮层内可选的应用（与业务层 SCRunningApplication 解耦的轻量模型）。
    struct FloatingApp: Identifiable, Equatable {
        let id: String      // bundleIdentifier
        let name: String
        let processID: pid_t
    }

    /// 实时转录模型选项。
    struct FloatingModelOption: Identifiable, Equatable {
        let id: String      // fileName（空 = 与转录模型相同）
        let name: String
    }

    /// 是否处于「选择应用」展开态（该阶段浮层放大为选择面板）。
    var isSelectingApp = false
    var appListPhase: AppListPhase = .idle
    var availableApps: [FloatingApp] = []
    var appSearchText = ""
    var selectedAppID: String?
    var appListError: String?

    // 录制选项（与原选择窗口保持一致，不丢功能）。
    // 麦克风初值读「音频」设置的默认包含麦克风。
    var includeMicrophone = UserDefaults.standard.bool(forKey: AudioConfiguration.includeMicrophoneKey)
    var enableLiveTranscription = true
    var enableLiveTranslation = false
    var liveModelOptions: [FloatingModelOption] = []
    var liveModelSelection = ""

    // MARK: 字幕容器（SubtitleContainerLayer）配置——与字体完全解耦

    /// 字幕容器宽度（独立于字号，400–1200）。
    var subtitleContainerWidth: CGFloat = 800
    /// 字幕容器高度（独立于字号，100–400）。
    var subtitleContainerHeight: CGFloat = 240
    /// 容器背景透明度。
    var subtitleBackgroundOpacity: Double = 0.34
    /// 字幕编辑边框（默认显示，可设置隐藏/颜色/透明度）。
    var subtitleEditBorderVisible = true
    /// 编辑边框颜色（十六进制字符串，如 "FFFFFF"）。
    var subtitleEditBorderColorHex = "FFFFFF"
    /// 编辑边框透明度（0–1）。
    var subtitleEditBorderOpacity: Double = 0.8

    // MARK: 字幕文字（SubtitleTextLayer）配置

    /// 字体粗细：regular / medium / bold。
    var subtitleFontWeight = "medium"
    /// 行间距（pt）。
    var subtitleLineSpacing: CGFloat = 2
    /// 原文（主字幕）字号。
    var sourceFontSize: CGFloat = 17
    /// 译文字号。
    var translationFontSize: CGFloat = 13
    /// 边框不透明度。
    var borderOpacity: Double = 0.1
    /// 字幕水平对齐（设置页可切换，默认居中；不影响窗口位置）。
    var subtitleTextAlignment: TextAlignment = .leading
}
