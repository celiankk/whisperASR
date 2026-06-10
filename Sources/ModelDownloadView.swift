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

            Text("Speech Recognition Model Required")
                .font(.headline)

            Text("WhisperASR needs a speech recognition model to transcribe audio. Choose one to download — you can add more or switch later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Picker("Model", selection: $selectedID) {
                ForEach(ModelCatalog.all) { m in
                    Text("\(m.displayName) (\(m.approxSizeText))").tag(m.id)
                }
            }

            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if downloader.hasResumeData {
                Text("A previous download of this model was interrupted and can be resumed.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Not Now") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(downloader.hasResumeData ? "Resume Download" : "Download") {
                    downloader.startDownload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var downloadingView: some View {
        VStack(spacing: 16) {
            Text("Downloading \(model.displayName)...")
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

            Button("Cancel") {
                downloader.cancelDownload()
            }
        }
    }

    private var completedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("Model Downloaded Successfully")
                .font(.headline)

            Text("\(model.displayName) has been saved and is ready to use.")
                .foregroundStyle(.secondary)

            Button("Done") {
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

            Text("Download Failed")
                .font(.headline)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Dismiss") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Retry") {
                    downloader.startDownload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
