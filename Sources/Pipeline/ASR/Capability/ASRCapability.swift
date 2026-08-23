import Foundation

// MARK: - 引擎能力描述（ASRCapability）
//
// 统一能力描述层：只陈述「每个 ASR 引擎能做什么」，供 UI 展示与
// 未来自动路由查询。纯静态数据——禁止放推理逻辑 / 模型加载逻辑 /
// Provider 运行状态（那些分别在 Provider / TranscriptionService / status()）。
//
// 数据流：
//
//   ASREngineType → ASRCapabilityRegistry.capability(for:) → UI / Router
//
// UI 按字段渲染（✓/△/✗），不出现 if engine == .funasr 式分支。

/// 推荐使用场景（描述性元数据，不影响任何运行时行为）。
enum ASRMode: Equatable, Sendable {
    /// 低延迟优先：流式出字、边说边显示（SenseVoice-streaming、Apple Speech）。
    case realtime
    /// 精度与延迟均衡：整句重转录但块小、反馈快（whisper 中小模型、在线 API）。
    case balanced
    /// 精度优先：大模型 / 长上下文转录（whisper large-turbo、Qwen3-ASR）。
    case accuracy
}

/// 单引擎能力快照。
struct ASRCapability: Equatable, Sendable {
    let engine: ASREngineType
    /// 流式喂音（音频持续进同一会话、只回增量文本；对应
    /// ASRMergePolicy.appendIncrement 的引擎语义）。
    let supportsStreaming: Bool
    /// 实时可出 partial 结果（非流式引擎每轮重转录 tail 也算——
    /// 字幕层拿到的同样是未封口 interim 文本）。
    let supportsPartialResult: Bool
    /// 时间戳质量：true = 引擎原生时间戳（whisper 对齐 / FunASR token 级 /
    /// Apple 段 range）；false = 无或按字符数估算（Qwen/Nemotron estimateSegments）。
    let supportsTimestamp: Bool
    /// 支持语言（ISO-639-1；空 = 自动检测不可枚举，UI 显示「多语言自动检测」）。
    let supportedLanguages: [String]
    /// 需要网络（在线 API）。
    let requiresNetwork: Bool
    /// 推荐场景。
    let recommendedMode: ASRMode

    /// 引擎是否支持手动指定识别语言（supportedLanguages 非空即可选；
    /// 空 + autoDetectOnly=false 表示仅系统/内置语言策略）。
    var supportsLanguageSelection: Bool { !supportedLanguages.isEmpty }

    /// 推荐场景标签。
    var modeLabel: String {
        switch recommendedMode {
        case .realtime: return "实时优先"
        case .balanced: return "均衡"
        case .accuracy: return "精度优先"
        }
    }

    /// 设置页能力清单（✓/△ 行数据源）：UI 按此渲染，
    /// 不感知具体引擎。supported 为 false 渲染为 △（弱支持/视配置而定）。
    var summaryEntries: [(label: String, supported: Bool)] {
        var entries: [(String, Bool)] = [
            ("推荐场景：\(modeLabel)", true),
            ("实时出字", supportsPartialResult),
            ("原生时间戳", supportsTimestamp),
        ]
        if supportedLanguages.isEmpty {
            entries.append(("多语言自动检测", true))
        } else if supportedLanguages.count > 4 {
            entries.append(("多语言（\(supportedLanguages.count) 种可选）", true))
        } else {
            let names = supportedLanguages.joined(separator: "/")
            entries.append(("语言：\(names)", true))
        }
        entries.append((requiresNetwork ? "需网络" : "本地运行", !requiresNetwork))
        return entries
    }
}
