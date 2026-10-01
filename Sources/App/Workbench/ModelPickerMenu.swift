import SwiftUI

/// 工具条/工作台头部的模型选择菜单：决定新音频用哪个模型转录。
/// 融合两类来源——ModelManager 下载目录（catalog）+ LocalModelManager 扫描到的
/// 本地自定义模型（如 LM Studio 模型目录），与 resolveModelPath 同一优先级：
/// 选中本地模型写入 modelPath（最高优先级）；选回 catalog/自动时清除 modelPath。
///
/// 原先住在 SidebarView.swift，历史栏重构后独立成文件。
struct ModelPickerMenu: View {
    @State private var manager = ModelManager.shared
    @State private var localModels = LocalModelManager.shared

    /// 本地模型在 Picker 中的 tag 前缀（与 catalog fileName 区分）。
    private static let localTagPrefix = "local:"

    /// 当前生效的自定义模型路径（文件必须存在，否则视为未设置）。
    private var activeCustomPath: String {
        let path = UserDefaults.standard.string(forKey: "modelPath") ?? ""
        return (!path.isEmpty && FileManager.default.fileExists(atPath: path)) ? path : ""
    }

    /// 转录模型选择绑定：本地模型 tag = "local:<完整路径>"。
    private var mainModelSelection: Binding<String> {
        Binding(
            get: {
                let custom = activeCustomPath
                return custom.isEmpty ? manager.selectedFileName : Self.localTagPrefix + custom
            },
            set: { value in
                if value.hasPrefix(Self.localTagPrefix) {
                    let path = String(value.dropFirst(Self.localTagPrefix.count))
                    UserDefaults.standard.set(path, forKey: "modelPath")
                    AppLogger.shared.log(.model, "Quick switch to local model: \(path)")
                } else {
                    // 选回下载模型/自动：必须清除自定义路径（否则它优先级最高，选择不生效）。
                    UserDefaults.standard.set("", forKey: "modelPath")
                    manager.selectedFileName = value
                    AppLogger.shared.log(.model,
                        "Quick switch to catalog model: \(value.isEmpty ? "自动" : value)")
                }
            }
        )
    }

    /// 菜单按钮标题：当前模型显示名。
    private var currentModelLabel: String {
        let custom = activeCustomPath
        if !custom.isEmpty {
            return (custom as NSString).deletingPathExtension
                .components(separatedBy: "/").last ?? "本地模型"
        }
        return manager.selectedModel?.displayName ?? "模型"
    }

    var body: some View {
        Menu {
            Picker("转录模型", selection: mainModelSelection) {
                Text("自动").tag("")
                ForEach(manager.downloadedModels) { model in
                    Text(model.displayName).tag(model.fileName)
                }
                if !localModels.models.isEmpty {
                    Divider()
                    ForEach(localModels.models) { model in
                        Text("\(model.name)（本地 \(model.sizeText)）")
                            .tag(Self.localTagPrefix + model.path)
                    }
                }
            }
            .pickerStyle(.inline)
            Picker("实时转录模型", selection: Binding(
                get: { manager.liveFileName },
                set: { manager.liveFileName = $0 }
            )) {
                Text("与转录模型相同").tag("")
                ForEach(manager.downloadedModels) { model in
                    Text(model.displayName).tag(model.fileName)
                }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsLink {
                Text("管理模型…")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                Text(currentModelLabel)
                    .font(Type.mono(Type.micro, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Corner.rect(Corner.tiny).fill(Ink.subtle))
            .overlay(Corner.rect(Corner.tiny).strokeBorder(Ink.hairline, lineWidth: 0.5))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("用于转录的模型：\(currentModelLabel)")
        .onAppear {
            manager.refresh()
            localModels.scan()
        }
    }
}
