import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

// MARK: - 通用

struct GeneralSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var apiServer = APIServer.shared

    // Backup & restore
    @State private var backupStatus: BackupStatus? = nil
    @State private var pendingRestore: BackupService.BackupFile? = nil
    @State private var showRestoreConfirm = false
    /// 端口输入是否被拒（越界值不写入配置，只在这里给提示）。
    @State private var portRejected = false

    private enum BackupStatus {
        case success(String)
        case failure(String)
    }

    /// 端口合法区间（与 GeneralSettings.apiServerPortRange 同一事实源）。
    private static let portRangeText = "1024-65535"

    /// 端口绑定：越界值**不写入配置**（保留旧值）。
    ///
    /// 为什么在 UI 层拦：APIServer.configuredPort 对越界值静默回落 8080，
    /// 若把用户输入的非法值存进配置，UI 显示的端口与实际监听端口就会
    /// 长期不一致（显示 99999、实际 8080）。
    private var portBinding: Binding<Int> {
        Binding(
            get: { settings.general.apiServerPort },
            set: { newValue in
                guard GeneralSettings.apiServerPortRange.contains(newValue) else {
                    portRejected = true
                    return
                }
                portRejected = false
                settings.general.apiServerPort = newValue
            }
        )
    }

    var body: some View {
        @Bindable var general = settings.general

        Form {
            Section(header: IconSectionHeader("外观", icon: "paintbrush", color: .purple)) {
                Picker("转录字体大小", selection: $general.transcriptFontSizeRaw) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: IconSectionHeader("基础选项", icon: "switch.2", color: .gray)) {
                Toggle(isOn: $general.enableLiveTranscription) {
                    RowLabel(title: "录制后生成转录记录",
                             detail: "关闭后不生成历史条目、不保留录音；实时字幕与翻译不受影响")
                }
            }

            Section(header: IconSectionHeader("本地 API 服务器（兼容 OpenAI）", icon: "server.rack", color: .cyan)) {
                Toggle("运行转录 API 服务器", isOn: $general.apiServerEnabled)
                    .onChange(of: general.apiServerEnabled) { _, on in
                        if on { apiServer.start() } else { apiServer.stop() }
                    }
                    // APIServer.markStopped 启动失败时会把 apiServerEnabled 写回
                    // false（外部写入，@Observable 观察不到）→ 开关会停在「开」。
                    // 服务器状态一变就回读一次，让开关与实际监听状态一致。
                    .onChange(of: apiServer.isRunning) { _, _ in
                        settings.general.refreshApiServerEnabled()
                    }

                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8080", value: portBinding, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(apiServer.isRunning)
                }
                Text(portRejected
                     ? "端口需在 \(Self.portRangeText) 之间，刚才的输入未保存（当前仍为 \(settings.general.apiServerPort)）。"
                     : "端口范围 \(Self.portRangeText)：小于 1024 需 root 权限，普通用户绑定会失败并被静默回落到 8080。")
                    .font(.caption)
                    .foregroundStyle(portRejected ? Color.red : Color.secondary)

                SecureField("API 密钥（可选）", text: $general.apiServerToken,
                            prompt: Text("留空以允许任何客户端"))
                    .textFieldStyle(.roundedBorder)

                Toggle("允许网络中其他设备访问", isOn: $general.apiServerAllowLAN)
                    .disabled(apiServer.isRunning)

                Toggle("详细请求日志（用于排查问题）", isOn: $general.apiServerVerboseLog)

                if apiServer.isRunning, let base = apiServer.baseURL {
                    HStack(spacing: 8) {
                        StatusBadge("运行中", level: .ok)
                        Text("\(base)/v1")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(base)/v1", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制基础 URL")
                        Spacer()
                    }
                } else if let err = apiServer.lastError {
                    StatusBadge(err, level: .error, lineLimit: 3)
                }

                Text("将任何兼容 OpenAI 的客户端指向上述地址（base_url）。端点：POST /v1/audio/transcriptions 和 /v1/audio/translations（multipart 格式，带 `file` 参数；response_format 支持 json、verbose_json、text、srt、vtt）。请求使用当前选择的模型。更改端口或网络设置后，需重新开关服务器才能生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("备份与恢复", icon: "externaldrive.badge.timemachine", color: .teal)) {
                HStack(spacing: 10) {
                    Button("导出备份…") { exportBackup() }
                    Button("从备份恢复…") { pickRestoreFile() }
                    Spacer()
                }

                switch backupStatus {
                case .success(let msg):
                    StatusBadge(msg, level: .ok)
                case .failure(let msg):
                    StatusBadge(msg, level: .error)
                case .none:
                    EmptyView()
                }

                Text("导出全部设置到文件（通用 / 识别 / 翻译 / 字幕 / 音频 / 浮层窗口 / 识别提示词全部分区，含翻译 API 密钥，请妥善保管）；转录内容需另行复制文件夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 页面出现时回读开关（覆盖「上次失败被 APIServer 写回 false」的残留状态）。
        .onAppear { settings.general.refreshApiServerEnabled() }
        .confirmationDialog(
            "从备份恢复？",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复") { performRestore() }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("这将用备份中的值覆盖当前设置（识别引擎与模型、在线/远程 API、翻译方式与参数、字幕样式、浮层偏好、本地 API 服务器、识别提示词、会议纪要提示词）。恢复后立即生效；转录内容不受影响。")
        }
    }

    // MARK: 备份与恢复

    private static func backupDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func exportBackup() {
        let backup = BackupService.makeBackup()
        guard let data = try? BackupService.encode(backup) else {
            backupStatus = .failure("无法生成备份数据。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WhisperASR Backup \(Self.backupDateString()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                backupStatus = .success("设置已导出。")
            } catch {
                backupStatus = .failure("导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                pendingRestore = try BackupService.decode(data)
                showRestoreConfirm = true
            } catch {
                backupStatus = .failure("无法读取备份：\(error.localizedDescription)")
            }
        }
    }

    private func performRestore() {
        guard let backup = pendingRestore else { return }
        BackupService.restore(backup)
        // restore 内部已把值应用回运行时（ConfigurationManager
        // .reloadAndApplyRuntime）；这里再 reload 一次让页面绑定的配置对象
        // 与磁盘保持一致（幂等）。
        settings.reload()
        backupStatus = .success("设置已恢复。")
        pendingRestore = nil
    }
}
