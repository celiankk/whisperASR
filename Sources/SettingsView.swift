import SwiftUI

struct SettingsView: View {
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("targetLanguage") private var targetLanguage = ""
    @AppStorage("translationEndpoint") private var translationEndpoint = ""
    @AppStorage("translationAPIKey") private var translationAPIKey = ""
    @AppStorage("translationModel") private var translationModel = ""

    var body: some View {
        Form {
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
                SecureField("API Key", text: $translationAPIKey,
                            prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $translationModel,
                          prompt: Text("gpt-4o-mini"))
                    .textFieldStyle(.roundedBorder)
                Text("Only API Key is required. Endpoint defaults to OpenAI, model defaults to gpt-4o-mini.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Whisper Model") {
                HStack {
                    TextField("GGML model file", text: $modelPath,
                              prompt: Text("Models/ggml-model.bin (auto-detected)"))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browseModel() }
                }
                Text("Leave empty to use Models/ggml-model.bin in the project directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model Setup") {
                Text("Convert the Breeze-ASR-25 model to GGML format:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("bash Scripts/convert_model.sh")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("This downloads and converts the model (~3 GB). Only needed once.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
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
