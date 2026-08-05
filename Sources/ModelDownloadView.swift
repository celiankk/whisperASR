import SwiftUI

struct ModelDownloadView: View {
    @Binding var isPresented: Bool
    @State private var manager = ModelManager.shared
    @State private var selectedID = ModelCatalog.all[0].id

    private var model: WhisperModelInfo {
        ModelCatalog.model(id: selectedID) ?? ModelCatalog.all[0]
    }

    private var downloader: ModelDownloader {
        manager.downloader(for: model)
    }

    var body: some View {
        VStack(spacing: 16) {
            switch downloader.state {
            case .prompt:
                promptView
            case .downloading:
                downloadingView
            case .completed:
                completedView
            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var promptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("需要语音识别模型")
                .font(.headline)

            Text("WhisperASR 需要语音识别模型才能转录音频。选择一个下载 — 你可以稍后在设置中添加更多或切换。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Picker("模型", selection: $selectedID) {
                ForEach(ModelCatalog.all) { m in
                    Text("\(m.displayName) (\(m.approxSizeText))").tag(m.id)
                }
            }

            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if downloader.hasResumeData {
                Text("此模型的上次下载被中断，可以继续下载。")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("暂不") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(downloader.hasResumeData ? "继续下载" : "下载") {
                    downloader.startDownload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var downloadingView: some View {
        VStack(spacing: 16) {
            Text("正在下载 \(model.displayName)…")
                .font(.headline)

            ProgressView(value: downloader.progress)
                .progressViewStyle(.linear)

            Text(downloader.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let eta = downloader.estimatedTimeRemaining {
                Text(eta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button("取消") {
                downloader.cancelDownload()
            }
        }
    }

    private var completedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("模型下载成功")
                .font(.headline)

            Text("\(model.displayName) 已保存并可以使用。")
                .foregroundStyle(.secondary)

            Button("完成") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("下载失败")
                .font(.headline)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("关闭") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("重试") {
                    downloader.startDownload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
