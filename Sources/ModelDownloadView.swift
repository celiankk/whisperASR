import SwiftUI

struct ModelDownloadView: View {
    @State private var downloader = ModelDownloader()
    @Binding var isPresented: Bool

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
        .frame(width: 420)
    }

    private var promptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Speech Recognition Model Required")
                .font(.headline)

            if downloader.hasResumeData {
                Text("A previous download was interrupted. Would you like to resume downloading the Breeze-ASR-25 model? The file is approximately 3 GB.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("WhisperASR needs the Breeze-ASR-25 model to transcribe audio. Would you like to download it automatically? The file is approximately 3 GB.")
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
            Text("Downloading Model...")
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

            Text("The model has been saved and is ready to use.")
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
