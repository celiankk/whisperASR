import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

// MARK: - 翻译

struct TranslationSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil
    @State private var benchmarkInFlight = false
    @State private var benchmarkSummary: String?

    private enum VerifyResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var translation = settings.translation
        let mode = translation.mode
        // 显式读取建立 Observable 依赖（菜单栏改 targetLanguage 时本页同步）。
        let _ = translation.targetLanguage

        Form {
            Section(header: IconSectionHeader("翻译", icon: "character.bubble", color: .orange)) {
                Picker(selection: $translation.mode) {
                    ForEach(TranslationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    RowLabel(title: "翻译方式", detail: modeDetail(mode))
                }

                if mode != .off {
                    Picker(selection: $translation.targetLanguage) {
                        Text("关闭").tag("")
                        ForEach(TargetLanguage.available) { lang in
                            Text(lang.nativeName).tag(lang.id)
                        }
                    } label: {
                        RowLabel(title: "目标语言")
                    }
                }
            }

            if mode == .localModel || mode == .onlineAPI {
                Section(header: IconSectionHeader(
                    mode == .localModel ? "本地模型配置" : "在线 API 配置",
                    icon: mode == .localModel ? "shippingbox" : "network",
                    color: mode == .localModel ? .indigo : .green)) {
                    TextField("API Base URL", text: $translation.endpoint,
                              prompt: Text(mode == .localModel ? "http://127.0.0.1:1234/v1" : "https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translation.endpoint) { _, _ in verifyResult = nil }
                    SecureField("API Key", text: $translation.apiKey,
                                prompt: Text(mode == .localModel ? "本地服务通常留空" : "sk-..."))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translation.apiKey) { _, _ in verifyResult = nil }
                    TextField("模型名称", text: $translation.model,
                              prompt: Text(mode == .localModel ? "留空自动检测" : "gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translation.model) { _, _ in verifyResult = nil }

                    // 思考模型兼容：禁思考参数注入（DeepSeek-R1/GLM/Qwen3 等
                    // 思考模型会把译文写进 reasoning_content 导致翻译空）。
                    HStack {
                        Text("思考模式")
                        Spacer()
                        Picker("", selection: $translation.thinkingControlRaw) {
                            ForEach(TranslationService.ThinkingControl.allCases, id: \.rawValue) { control in
                                Text(control.label).tag(control.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .pickerStyle(.menu)
                    }
                    Text("DeepSeek-R1 / GLM / Qwen3 等思考模型自动禁思考，防止译文为空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("上下文句数")
                        Spacer()
                        Stepper("\(translation.contextRounds) 句", value: $translation.contextRounds, in: 0...8)
                            .frame(width: 130)
                    }
                    Text("携带最近 N 句译文保持术语一致；0 = 关闭。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("请求超时时间")
                        Spacer()
                        TextField("30", value: $translation.timeout, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("最大上下文长度")
                        Spacer()
                        TextField("16000", value: $translation.maxContext, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                        Text("tokens")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("温度参数")
                        Slider(value: $translation.temperature, in: 0...2, step: 0.1)
                            .frame(width: 160)
                        Text(translation.temperature, format: .number.precision(.fractionLength(1)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }

                    Text(mode == .localModel
                         ? "自动探测 1234（LM Studio）/ 11434（Ollama）/ 8080（llama.cpp）"
                         : "请求异步执行，失败自动重试，不阻塞字幕显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            verifyConnection()
                        } label: {
                            if verifyInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("检测 API 状态")
                            }
                        }
                        .disabled(
                            verifyInFlight
                                || (mode == .onlineAPI && !TranslationService.isAPIConfigured)
                        )

                        switch verifyResult {
                        case .success(let msg):
                            StatusBadge(msg, level: .ok)
                        case .failure(let msg):
                            StatusBadge(msg, level: .error)
                        case .none:
                            EmptyView()
                        }
                        Spacer()
                    }

                    // 翻译基准：固定 3 句样本走当前配置（流式单句路径），
                    // 供本地/在线/各模型之间横向比较速度与输出质量。
                    HStack(spacing: 10) {
                        Button {
                            runBenchmark()
                        } label: {
                            if benchmarkInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("基准测试")
                            }
                        }
                        .disabled(benchmarkInFlight || verifyInFlight)
                        if let summary = benchmarkSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer()
                    }
                }

                // 翻译提示词：独立区块（预设 + 模板编辑 + 变量插入 +
                // 恢复默认/保存；变量替换统一走 PromptBuilder）。
                // 仅 LLM 翻译（本地/在线）使用；Apple 翻译不经过提示词。
                if mode != .apple {
                    Section(header: IconSectionHeader("翻译提示词", icon: "text.quote", color: .orange)) {
                        TranslationPromptEditor(translation: translation)
                    }
                }
            }

            // 公共免 Key 通道（Google v1 / Google v2 / 微软）：零配置。
            // 这些端点不接受 system prompt，提示词预设对其无效，故不显示
            // 配置区与提示词编辑区，只给连通性检测与基准测试。
            if let channel = mode.freeWebChannel {
                Section(header: IconSectionHeader("公共免 Key 通道", icon: "globe", color: .teal)) {
                    Text(channel.detail)
                    Text("音频 → 实时识别 → \(channel.label) → 目标语言字幕（整句返回，无需 API Key）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            verifyConnection()
                        } label: {
                            if verifyInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("检测通道状态")
                            }
                        }
                        .disabled(verifyInFlight)

                        switch verifyResult {
                        case .success(let msg):
                            StatusBadge(msg, level: .ok)
                        case .failure(let msg):
                            StatusBadge(msg, level: .error)
                        case .none:
                            EmptyView()
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            runBenchmark()
                        } label: {
                            if benchmarkInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("基准测试")
                            }
                        }
                        .disabled(benchmarkInFlight || verifyInFlight)
                        if let summary = benchmarkSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer()
                    }

                    Text("公共端点为非官方接口：按请求量限流（429 自动退避重试），"
                         + "长时段高频使用可能失败；不可用时请切换其他翻译方式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 「翻译方式」行说明文案。
    private func modeDetail(_ mode: TranslationMode) -> String {
        switch mode {
        case .off: return "关闭实时字幕翻译"
        case .localModel: return "LM Studio / Ollama / llama.cpp；地址与模型可自动探测"
        case .onlineAPI: return "音频 → 实时识别 → 在线 API 翻译 → 目标语言字幕"
        case .googleV1, .googleV2, .microsoft:
            return (mode.freeWebChannel?.detail ?? "") + " · 无需配置"
        case .apple: return "音频 → 实时识别 → Apple 翻译 → 目标语言字幕（macOS 26+）"
        }
    }

    /// 翻译基准：3 句样本（中英混合短/中/长句）串行走当前翻译配置，
    /// 输出总耗时 / 平均耗时 / 译文预览。失败显示错误。
    private func runBenchmark() {
        benchmarkInFlight = true
        benchmarkSummary = nil
        let samples = [
            "今天天气很好，我们出去走走吧。",
            "The quick brown fox jumps over the lazy dog near the river bank at dawn.",
            "会议纪要：项目进度已过半，测试阶段预计下周开始，请各团队准备好验收材料并及时同步风险。"
        ]
        let target = settings.translation.targetLanguage.isEmpty
            ? "en" : settings.translation.targetLanguage
        let mode = settings.translation.mode
        Task {
            var total: Double = 0
            var outputs: [String] = []
            var failure: String?
            for sample in samples {
                let start = Date()
                do {
                    let text: String
                    if mode.isFreeWebChannel {
                        // 公共免 key 通道：走 Provider 的非流式 translate
                        // （协议默认实现，等价于整句返回）。
                        let result = try await TranslationManager.provider(for: mode).translate(
                            TranslationRequest(text: sample, targetLanguage: target))
                        text = result.texts.first ?? ""
                    } else {
                        text = try await TranslationService.translateStreaming(
                            segmentText: sample, targetLanguage: target,
                            local: mode == .localModel) { _ in }
                    }
                    total += Date().timeIntervalSince(start)
                    outputs.append(text)
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            await MainActor.run {
                benchmarkInFlight = false
                if let failure {
                    benchmarkSummary = "失败：\(failure)"
                } else {
                    let avg = total / Double(max(1, outputs.count))
                    benchmarkSummary = String(
                        format: "3 句共 %.1fs（平均 %.2fs/句）｜示例：%@",
                        total, avg, outputs.first.map { String($0.prefix(24)) } ?? "")
                }
            }
        }
    }

    private func verifyConnection() {
        verifyInFlight = true
        verifyResult = nil
        let mode = settings.translation.mode
        let lang = settings.translation.targetLanguage.isEmpty
            ? "en" : settings.translation.targetLanguage
        Task {
            do {
                let sample: String
                if mode.isFreeWebChannel {
                    // 公共免 key 通道：直接走 Provider（无端点/Key 配置）。
                    let result = try await TranslationManager.provider(for: mode).translate(
                        TranslationRequest(text: "Hello, world.", targetLanguage: lang))
                    sample = result.texts.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } else {
                    let translations = try await TranslationService.translateSegmentsWithOpenAI(
                        segmentTexts: ["Hello, world."],
                        targetLanguage: lang,
                        local: mode == .localModel
                    )
                    sample = translations.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                await MainActor.run {
                    verifyInFlight = false
                    if sample.isEmpty {
                        verifyResult = .failure("Empty response")
                    } else {
                        verifyResult = .success("OK — \(sample)")
                    }
                }
            } catch {
                await MainActor.run {
                    verifyInFlight = false
                    verifyResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - 翻译提示词预设（场景化风格库）

// TranslationPromptPreset 已迁移至 Pipeline/Translation/TranslationPromptPreset.swift
// （Pipeline 层——设置页与翻译运行时共用；变量化模板见 PromptBuilder）。

/// 翻译提示词编辑器（设置 → 翻译）：预设选择即时加载对应模板，
/// 编辑区修改后「保存」持久化（保存即视为自定义态）；「恢复默认」
/// 重载当前预设原始模板；变量点击追加到编辑区（不做复杂编辑器）。
private struct TranslationPromptEditor: View {
    @Bindable var translation: TranslationConfiguration
    /// 编辑缓冲（未保存的修改；保存时写回 translation.systemPrompt）。
    @State private var draft: String = ""
    /// 已加载到缓冲的来源（预设 id / customID），驱动恢复默认与描述显示。
    @State private var loadedID: String = ""
    @State private var saveConfirmation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("翻译风格")
                Spacer()
                Picker("", selection: $loadedID) {
                    ForEach(TranslationPromptPreset.all, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    Text(TranslationPromptPreset.customID).tag(TranslationPromptPreset.customID)
                }
                .labelsHidden()
                .frame(width: 150)
                .pickerStyle(.menu)
                .onChange(of: loadedID) { _, newValue in
                    loadPreset(id: newValue)
                }
            }

            // 当前预设的场景描述（自定义态不显示）。
            if let preset = TranslationPromptPreset.with(id: loadedID) {
                Text("\(preset.name)：\(preset.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))

            // 变量说明（点击追加到编辑区末尾）。
            HStack(spacing: 10) {
                Text("可用变量：").font(.caption).foregroundStyle(.secondary)
                ForEach([("{source_lang}", "源语言"),
                         ("{target_lang}", "目标语言"),
                         ("{text}", "待翻译文本")], id: \.0) { variable, hint in
                    Button {
                        draft += variable
                    } label: {
                        Text("\(variable) \(hint)")
                            .font(.caption)
                            .monospaced()
                    }
                    .buttonStyle(.link)
                    .help("点击插入 \(variable)")
                }
            }

            HStack {
                Button("恢复默认") { restoreDefault() }
                    .disabled(TranslationPromptPreset.with(id: loadedID) == nil)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == translation.systemPrompt)
                if let saveConfirmation {
                    StatusBadge(saveConfirmation, level: .ok)
                }
                Spacer()
            }

            Text("模板支持变量替换（发送前统一执行）；留空使用默认翻译指令。编号输出格式要求会自动追加，无需写入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadPersisted() }
    }

    /// 当前缓冲内容对应的预设（与内置模板全等才算选中该预设）。
    private func matchedPreset() -> TranslationPromptPreset? {
        TranslationPromptPreset.all.first { $0.prompt == draft }
    }

    /// 启动时按持久化状态恢复（用户配置兼容）：
    /// - 已保存过 Prompt（systemPrompt 非空）→ 原样加载，不覆盖；
    /// - 首次安装（无任何配置）→ 加载默认预设「视频字幕」并落盘；
    /// - 持久化的预设 id 已不存在（预设被移除）→ 显示自定义态，内容保留。
    private func loadPersisted() {
        let savedID = translation.translationPromptPreset
        let savedPrompt = translation.systemPrompt
        if savedPrompt.isEmpty && savedID.isEmpty {
            // 首次安装：应用默认预设「视频字幕」。
            if let preset = TranslationPromptPreset.with(id: TranslationPromptPreset.defaultID) {
                draft = preset.prompt
                loadedID = preset.id
                translation.systemPrompt = preset.prompt
                translation.translationPromptPreset = preset.id
            }
            return
        }
        draft = savedPrompt
        // 保存内容与某内置模板全等 → 高亮该预设；否则自定义态。
        if let preset = matchedPreset() {
            loadedID = preset.id
        } else {
            loadedID = TranslationPromptPreset.customID
        }
        _ = savedID  // 旧 id 仅作参考；显示以内容匹配为准（预设改名/替换不破坏内容）
    }

    /// 切换预设：立即加载对应模板到编辑区（未保存，需点保存写入）。
    private func loadPreset(id: String) {
        guard let preset = TranslationPromptPreset.with(id: id) else { return }
        draft = preset.prompt
        saveConfirmation = nil
    }

    /// 恢复默认：重载当前预设的原始模板。
    private func restoreDefault() {
        guard let preset = TranslationPromptPreset.with(id: loadedID) else { return }
        draft = preset.prompt
    }

    /// 保存：写回配置（持久化）；与任何内置预设不同即标记自定义态。
    private func save() {
        translation.systemPrompt = draft
        if let preset = matchedPreset() {
            translation.translationPromptPreset = preset.id
        } else {
            translation.translationPromptPreset = TranslationPromptPreset.customID
        }
        saveConfirmation = "已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveConfirmation = nil }
    }
}
