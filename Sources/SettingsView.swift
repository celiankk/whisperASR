import SwiftUI

struct SettingsView: View {
    @AppStorage("transcriptFontSize") private var transcriptFontSize = TranscriptFontSize.normal.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("targetLanguage") private var targetLanguage = ""
    @AppStorage("translationEndpoint") private var translationEndpoint = ""
    @AppStorage("translationAPIKey") private var translationAPIKey = ""
    @AppStorage("translationModel") private var translationModel = ""

    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil

    private enum VerifyResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Transcript Font Size", selection: $transcriptFontSize) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Translation") {
                Picker("Target Language", selection: $targetLanguage) {
                    Text("Off").tag("")
                    ForEach(TargetLanguage.available) { lang in
                        Text(lang.nativeName).tag(lang.id)
                    }
                }
                Text("Translate live transcription to this language using an OpenAI-compatible API configured below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI Translation API") {
                TextField("API Endpoint", text: $translationEndpoint,
                          prompt: Text("https://api.openai.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationEndpoint) { _, _ in verifyResult = nil }
                SecureField("API Key", text: $translationAPIKey,
                            prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationAPIKey) { _, _ in verifyResult = nil }
                TextField("Model", text: $translationModel,
                          prompt: Text("gpt-4o-mini"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationModel) { _, _ in verifyResult = nil }
                Text("Only API Key is required. Endpoint defaults to OpenAI, model defaults to gpt-4o-mini.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        verifyConnection()
                    } label: {
                        if verifyInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify Connection")
                        }
                    }
                    .disabled(verifyInFlight || translationAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    switch verifyResult {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    case .none:
                        EmptyView()
                    }
                    Spacer()
                }
            }

            Section("Speech Recognition Models") {
                ForEach(ModelCatalog.all) { model in
                    ModelRowView(model: model)
                }
                Text("Select a downloaded model to use it for transcription. Smaller models are faster but less accurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Model") {
                HStack {
                    TextField("GGML model file", text: $modelPath,
                              prompt: Text("Path to a custom ggml model"))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browseModel() }
                }
                Text("Used only when no model is selected above. Leave empty otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear { ModelManager.shared.refresh() }
    }

    private func verifyConnection() {
        verifyInFlight = true
        verifyResult = nil
        let lang = targetLanguage.isEmpty ? "en" : targetLanguage
        Task {
            do {
                let translations = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: ["Hello, world."],
                    targetLanguage: lang
                )
                await MainActor.run {
                    verifyInFlight = false
                    let sample = translations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                modelPath = url.path
            }
        }
    }
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: WhisperModelInfo
    @State private var manager = ModelManager.shared
    @State private var confirmDelete = false

    private var downloader: ModelDownloader { manager.downloader(for: model) }
    private var isDownloaded: Bool { manager.isDownloaded(model) }
    private var isSelected: Bool { manager.selectedFileName == model.fileName }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                manager.selectedFileName = model.fileName
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .help(isDownloaded ? "Use this model for transcription" : "Download the model first")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.detail) · \(model.approxSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloaded {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete downloaded model")
            } else if downloader.state == .downloading {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    downloader.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            } else {
                if case .failed = downloader.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Download failed — click Download to retry")
                }
                Button(downloader.hasResumeData ? "Resume" : "Download") {
                    downloader.startDownload()
                }
            }
        }
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                manager.delete(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model file (\(model.approxSizeText)) will be removed from disk. You can download it again later.")
        }
    }
}
