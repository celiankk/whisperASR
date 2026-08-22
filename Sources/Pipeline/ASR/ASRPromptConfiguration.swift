import Foundation
import Observation

// MARK: - ASR Prompt 配置（ASRPromptConfiguration）
//
// 语音识别提示词（热词/术语注入）配置。挂载于 ConfigurationManager.asrPrompt。
//
// 字段（UserDefaults 持久化，键 1.4 风格，旧配置兼容）：
// - enabled        总开关（关闭 = 不注入，无 Prompt 模型不受影响）
// - source         来源：手动输入 / 场景模板 / 历史词库 / AI 生成
// - customPrompt   手动输入的专业词汇 / 产品名 / 人名
// - sceneTemplate  场景模板（技术会议 / 游戏 / 影视 / 新闻 / 课程）
// - keywords       附加关键词（逗号分隔，叠加到任意来源之上）
//
// 生成时机（ASRPromptManager.refresh）：启动识别 / 切换场景 / 修改配置，
// 不会每句话调用。

/// Prompt 来源。
enum ASRPromptSource: String, CaseIterable, Codable {
    case manual
    case scene
    case history
    case ai

    var label: String {
        switch self {
        case .manual: return "手动输入"
        case .scene: return "场景模板"
        case .history: return "历史词库"
        case .ai: return "AI 生成"
        }
    }
}

/// 场景模板：自动生成基础 Prompt（中英混合热词）。
enum ASRSceneTemplate: String, CaseIterable, Codable {
    case techMeeting
    case game
    case movie
    case news
    case course

    var label: String {
        switch self {
        case .techMeeting: return "技术会议"
        case .game: return "游戏"
        case .movie: return "影视"
        case .news: return "新闻"
        case .course: return "课程"
        }
    }

    /// 场景基础 Prompt 文本（注入为识别提示词）。
    var promptText: String {
        switch self {
        case .techMeeting:
            return "以下是技术会议常见词汇：架构、部署、评审、迭代、接口、数据库、缓存、"
                + "API、SDK、commit、merge、sprint、上线、回滚、监控、告警、需求、方案、"
                + "排期、验收、回归测试、性能优化、容器、微服务"
        case .game:
            return "以下是游戏相关词汇：副本、装备、技能、等级、匹配、排位、团战、补刀、"
                + "boss、buff、nerf、patch、版本、活动、皮肤、抽卡、阵容、段位、连招、"
                + "战场、竞技、攻略、更新"
        case .movie:
            return "以下是影视相关词汇：导演、编剧、镜头、剪辑、配音、字幕、特效、预告、"
                + "票房、档期、主演、配角、情节、结局、片尾、彩蛋、剧集、评分、首映、"
                + "角色、剧本、场记"
        case .news:
            return "以下是新闻相关词汇：记者、报道、发布会、政策、经济、民生、国际、"
                + "外交、谈判、峰会、选举、疫情、灾害、救援、调查、声明、回应、评论、"
                + "专题、现场、直播、数据"
        case .course:
            return "以下是课程学习相关词汇：知识点、章节、例题、公式、定理、推导、"
                + "作业、考试、复习、笔记、讲义、课件、大纲、学分、必修、选修、实验、"
                + "课题、论文、答辩、错题、重点"
        }
    }
}

@Observable
final class ASRPromptConfiguration {
    /// 总开关：关闭时不生成、不注入（无 Prompt 模型不受影响）。
    var enabled = false {
        didSet {
        UserDefaults.standard.set(enabled, forKey: Self.keyEnabled)
        scheduleRefresh()
    }
    }
    /// Prompt 来源。
    var source: ASRPromptSource = .manual {
        didSet {
        UserDefaults.standard.set(source.rawValue, forKey: Self.keySource)
        scheduleRefresh()
    }
    }
    /// 手动输入内容（专业词汇 / 产品名 / 人名）。
    var customPrompt = "" {
        didSet {
        UserDefaults.standard.set(customPrompt, forKey: Self.keyCustom)
        scheduleRefresh()
    }
    }
    /// 场景模板。
    var sceneTemplate: ASRSceneTemplate = .techMeeting {
        didSet {
        UserDefaults.standard.set(sceneTemplate.rawValue, forKey: Self.keyScene)
        scheduleRefresh()
    }
    }
    /// 附加关键词（逗号分隔；叠加到任意来源之上）。
    var keywords = "" {
        didSet {
        UserDefaults.standard.set(keywords, forKey: Self.keyKeywords)
        scheduleRefresh()
    }
    }
    /// AI 生成结果缓存（生成只在启动识别/切换场景/修改配置时进行）。
    var aiGeneratedPrompt = "" {
        didSet { UserDefaults.standard.set(aiGeneratedPrompt, forKey: Self.keyAIGenerated) }
    }

    static let keyEnabled = "asrPromptEnabled"
    static let keySource = "asrPromptSource"
    static let keyCustom = "asrPromptCustom"
    static let keyScene = "asrPromptScene"
    static let keyKeywords = "asrPromptKeywords"
    static let keyAIGenerated = "asrPromptAIGenerated"

    init() { reload() }

    /// 配置变更后异步刷新当前 Prompt（启动识别时也会 refresh）。
    /// 异步避免 ConfigurationManager 初始化期间同步访问单例。
    private func scheduleRefresh() {
        DispatchQueue.main.async { ASRPromptManager.shared.refresh() }
    }

    func reload() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Self.keyEnabled)
        source = ASRPromptSource(rawValue: defaults.string(forKey: Self.keySource) ?? "") ?? .manual
        customPrompt = defaults.string(forKey: Self.keyCustom) ?? ""
        sceneTemplate = ASRSceneTemplate(rawValue: defaults.string(forKey: Self.keyScene) ?? "")
            ?? .techMeeting
        keywords = defaults.string(forKey: Self.keyKeywords) ?? ""
        aiGeneratedPrompt = defaults.string(forKey: Self.keyAIGenerated) ?? ""
    }
}
