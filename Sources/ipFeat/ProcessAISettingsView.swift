import SwiftUI

struct ProcessAISettingsView: View {
    @StateObject private var settings = ProcessAISettings.shared
    @State private var editingID = UUID()
    @State private var name = ""
    @State private var provider: ProcessAIProvider = .ollama
    @State private var endpoint = ProcessAIProvider.ollama.defaultEndpoint
    @State private var model = ""
    @State private var language: ProcessAILanguage = .system
    @State private var customLanguage = ""
    @State private var key = ""
    @State private var message = ""
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("AI help for process route prompts")
                    .font(.title2.bold())
                Text("Add several cloud or local models and select the one used by the ? button in a route prompt. AI only explains the process; you choose the route.")
                    .foregroundStyle(.secondary)

                HStack {
                    Picker("Active model", selection: Binding(
                        get: { settings.selectedProfileID },
                        set: { id in settings.select(id); loadSelected() }
                    )) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(settings.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .frame(maxWidth: 430)
                    Button("Add model") { newProfile() }
                    Button("Delete") {
                        settings.remove(editingID)
                        loadSelected()
                    }
                    .disabled(!settings.profiles.contains(where: { $0.id == editingID }))
                }

                Divider()
                TextField("Name", text: $name)
                Picker("Provider", selection: $provider) {
                    ForEach(ProcessAIProvider.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                HStack {
                    TextField("Endpoint URL", text: $endpoint)
                    Button("Use default URL") { endpoint = provider.defaultEndpoint }
                    Menu("Presets") {
                        Button("DeepSeek · OpenAI-compatible") {
                            useDeepSeek(provider: .openAICompatible,
                                        endpoint: "https://api.deepseek.com/chat/completions")
                        }
                        Button("DeepSeek · Anthropic-compatible") {
                            useDeepSeek(provider: .anthropic,
                                        endpoint: "https://api.deepseek.com/anthropic/v1/messages")
                        }
                    }
                }
                TextField("Model ID", text: $model)
                Picker("Request and answer language", selection: $language) {
                    ForEach(ProcessAILanguage.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if language == .custom {
                    TextField("Language name, for example Español", text: $customLanguage)
                    Text("For other languages, the request text stays in English and asks the model to answer in the named language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField("API key (leave blank to keep saved key)", text: $key)
                if ProcessAIKeychain.load(id: editingID) != nil {
                    HStack {
                        Label("API key saved in Keychain", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Button("Remove key") {
                            ProcessAIKeychain.delete(id: editingID)
                            key = ""
                            message = "Saved API key removed."
                        }
                    }
                }
                HStack {
                    Button("Save model") { save() }
                    Button("Test model") { test() }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                Text("Test uses the fields currently shown. Save the model to use it from route prompt windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Divider()
                Text("Only the executable path, immediate parent path and registered app name are sent after you click ? in a route prompt. Command arguments, environment variables and credentials are not sent. Local Ollama and local OpenAI-compatible endpoints can use HTTP on this Mac; API keys for remote endpoints require HTTPS. The route window stays open while the model responds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear { loadSelected() }
    }

    private func loadSelected() {
        guard let profile = settings.selectedProfile else { newProfile(); return }
        editingID = profile.id
        name = profile.name
        provider = profile.provider
        endpoint = profile.endpoint
        model = profile.model
        language = profile.language
        customLanguage = profile.customLanguage
        key = ""
        message = ""
    }

    private func newProfile() {
        editingID = UUID()
        name = ""
        provider = .ollama
        endpoint = ProcessAIProvider.ollama.defaultEndpoint
        model = ""
        language = .system
        customLanguage = ""
        key = ""
        message = ""
    }

    private func save() {
        do {
            try settings.save(ProcessAIProfile(id: editingID, name: name, provider: provider,
                                               endpoint: endpoint, model: model,
                                               language: language, customLanguage: customLanguage),
                              key: key.isEmpty ? nil : key)
            key = ""
            message = "Model saved and selected."
        } catch {
            message = error.localizedDescription
        }
    }

    private func useDeepSeek(provider selectedProvider: ProcessAIProvider, endpoint selectedEndpoint: String) {
        if name.isEmpty { name = "DeepSeek" }
        provider = selectedProvider
        endpoint = selectedEndpoint
        model = "deepseek-flash"
        message = "Preset filled. Test the current fields, then save the model."
    }

    private func test() {
        let profile = ProcessAIProfile(id: editingID, name: name.isEmpty ? "Test" : name,
                                       provider: provider, endpoint: endpoint, model: model,
                                       language: language, customLanguage: customLanguage)
        isTesting = true
        message = "Testing the current fields…"
        Task {
            do {
                let response = try await ProcessAIClient.explain(
                    processPath: "/usr/bin/curl", parentPath: "/bin/zsh",
                    applicationName: "Model test", profile: profile,
                    apiKey: key.isEmpty ? nil : key
                )
                message = "Connected. \(response)"
            } catch {
                message = error.localizedDescription
            }
            isTesting = false
        }
    }
}
