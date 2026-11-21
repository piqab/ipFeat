import Foundation
import Security

enum ProcessAIProvider: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "OpenAI-compatible"
    case ollama = "Ollama"
    case anthropic = "Anthropic"
    case gemini = "Gemini"

    var id: String { rawValue }

    var defaultEndpoint: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1/chat/completions"
        case .ollama: "http://127.0.0.1:11434/api/chat"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

enum ProcessAILanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case russian
    case english
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "macOS language"
        case .russian: "Русский"
        case .english: "English"
        case .custom: "Other language…"
        }
    }
}

struct ProcessAIProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var provider: ProcessAIProvider
    var endpoint: String
    var model: String
    var language: ProcessAILanguage
    var customLanguage: String

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, endpoint, model, language, customLanguage
    }

    init(id: UUID = UUID(), name: String, provider: ProcessAIProvider, endpoint: String,
         model: String, language: ProcessAILanguage = .system, customLanguage: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.customLanguage = customLanguage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        provider = try values.decode(ProcessAIProvider.self, forKey: .provider)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        language = try values.decodeIfPresent(ProcessAILanguage.self, forKey: .language) ?? .system
        customLanguage = try values.decodeIfPresent(String.self, forKey: .customLanguage) ?? ""
    }
}

struct ProcessAISettingsSnapshot: Codable {
    var profiles: [ProcessAIProfile]
    var selectedProfileID: UUID?
    var keys: [String: String]
}

@MainActor
final class ProcessAISettings: ObservableObject {
    static let shared = ProcessAISettings()
    private static let defaultsKey = "processAISettings"

    @Published private(set) var profiles: [ProcessAIProfile] = []
    @Published private(set) var selectedProfileID: UUID?

    var selectedProfile: ProcessAIProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    private struct Stored: Codable {
        var profiles: [ProcessAIProfile]
        var selectedProfileID: UUID?
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            profiles = stored.profiles
            selectedProfileID = stored.selectedProfileID
        }
    }

    func save(_ profile: ProcessAIProfile, key: String?) throws {
        let trimmed = ProcessAIProfile(id: profile.id,
                                       name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       provider: profile.provider,
                                       endpoint: profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                       model: profile.model.trimmingCharacters(in: .whitespacesAndNewlines),
                                       language: profile.language,
                                       customLanguage: profile.customLanguage.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.name.isEmpty, !trimmed.model.isEmpty else {
            throw ProcessAIError.invalidSettings("Enter a profile name and model.")
        }
        try ProcessAIClient.validateProfileEndpoint(trimmed, key: key ?? ProcessAIKeychain.load(id: profile.id))
        try ProcessAIClient.validateProfileLanguage(trimmed)
        if let key, !key.isEmpty { try ProcessAIKeychain.save(key, id: profile.id) }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = trimmed
        } else {
            profiles.append(trimmed)
        }
        selectedProfileID = trimmed.id
        persist()
    }

    func select(_ id: UUID?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        persist()
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        ProcessAIKeychain.delete(id: id)
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
        persist()
    }

    func snapshot() throws -> ProcessAISettingsSnapshot {
        var keys: [String: String] = [:]
        for profile in profiles {
            if let key = try ProcessAIKeychain.loadChecked(id: profile.id) {
                keys[profile.id.uuidString] = key
            }
        }
        return ProcessAISettingsSnapshot(profiles: profiles, selectedProfileID: selectedProfileID, keys: keys)
    }

    func restore(_ snapshot: ProcessAISettingsSnapshot) throws {
        let oldIDs = Set(profiles.map(\.id))
        let newIDs = Set(snapshot.profiles.map(\.id))
        for id in oldIDs.subtracting(newIDs) { try ProcessAIKeychain.deleteChecked(id: id) }
        for profile in snapshot.profiles {
            if let key = snapshot.keys[profile.id.uuidString] {
                try ProcessAIKeychain.save(key, id: profile.id)
            } else {
                try ProcessAIKeychain.deleteChecked(id: profile.id)
            }
        }
        profiles = snapshot.profiles
        if let selected = snapshot.selectedProfileID {
            selectedProfileID = snapshot.profiles.contains(where: { $0.id == selected })
                ? selected : snapshot.profiles.first?.id
        } else {
            selectedProfileID = nil
        }
        persist()
    }

    private func persist() {
        let stored = Stored(profiles: profiles, selectedProfileID: selectedProfileID)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum ProcessAIKeychain {
    private static let service = "local.ipinformer.process-ai"

    static func save(_ key: String, id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = Data(key.utf8)
            let inserted = SecItemAdd(addition as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(id: UUID) -> String? {
        try? loadChecked(id: id)
    }

    static func loadChecked(id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else {
            throw NSError(domain: "IPInformer.ProcessAIKeychain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppLanguage.localized("AI key in Keychain is not data")])
        }
        guard let key = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "IPInformer.ProcessAIKeychain", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: AppLanguage.localized("AI key in Keychain is not UTF-8")])
        }
        return key
    }

    static func delete(id: UUID) {
        try? deleteChecked(id: id)
    }

    static func deleteChecked(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

enum ProcessAIError: LocalizedError {
    case invalidSettings(String)
    case server(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message): message
        case .server(let status, let message): "HTTP \(status): \(message)"
        case .invalidResponse: "The model returned an unreadable response."
        }
    }
}

enum ProcessAIClient {
    static func validateEndpoint(_ endpoint: String, key: String?) throws {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ProcessAIError.invalidSettings("Enter a valid HTTP or HTTPS endpoint without credentials in the URL.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        if scheme != "https" && !loopback {
            throw ProcessAIError.invalidSettings("Use HTTPS for remote models. HTTP is supported for a model on this Mac.")
        }
    }

    static func validateProfileEndpoint(_ profile: ProcessAIProfile, key: String?) throws {
        _ = try resolvedURL(for: profile, key: key)
    }

    static func validateProfileLanguage(_ profile: ProcessAIProfile) throws {
        _ = try requestText(processPath: "", parentPath: nil, applicationName: nil, profile: profile)
    }

    private static func resolvedURL(for profile: ProcessAIProfile, key: String?) throws -> URL {
        try validateEndpoint(profile.endpoint, key: key)
        var url = URL(string: profile.endpoint)!
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "api.deepseek.com" {
            if profile.provider == .openAICompatible && path.hasPrefix("anthropic") {
                throw ProcessAIError.invalidSettings("This is DeepSeek's Anthropic endpoint. For OpenAI-compatible, use https://api.deepseek.com/chat/completions; or select Anthropic and use https://api.deepseek.com/anthropic/v1/messages.")
            }
            if profile.model == "deepseek-chat" || profile.model == "deepseek-reasoner" {
                throw ProcessAIError.invalidSettings("DeepSeek retired this model name. Use deepseek-flash or deepseek-v4-pro.")
            }
        }
        switch profile.provider {
        case .openAICompatible:
            if path.isEmpty {
                url.appendPathComponent(host == "api.deepseek.com" ? "chat/completions" : "v1/chat/completions")
            } else if path == "v1" {
                url.appendPathComponent("chat/completions")
            }
        case .ollama:
            if path.isEmpty { url.appendPathComponent("api/chat") }
        case .anthropic:
            if path.isEmpty || path == "anthropic" || path == "v1" {
                url.appendPathComponent(path == "v1" ? "messages" : "v1/messages")
            }
        case .gemini:
            break
        }
        return url
    }

    static func explain(processPath: String, parentPath: String?, applicationName: String?,
                        profile: ProcessAIProfile, apiKey: String? = nil,
                        session: URLSession = .shared) async throws -> String {
        let key = apiKey ?? ProcessAIKeychain.load(id: profile.id)
        let request = try makeRequest(processPath: processPath, parentPath: parentPath,
                                      applicationName: applicationName, profile: profile, key: key)
        let (data, response) = try await session.data(for: request)
        guard data.count <= 1_000_000 else { throw ProcessAIError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw ProcessAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data.prefix(300), encoding: .utf8) ?? "Request failed"
            throw ProcessAIError.server(http.statusCode, text)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessAIError.invalidResponse
        }
        let content: String?
        switch profile.provider {
        case .openAICompatible:
            let choices = json["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            content = message?["content"] as? String
        case .ollama:
            content = (json["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            content = (json["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]]
            let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            content = parts?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessAIError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeRequest(processPath: String, parentPath: String?, applicationName: String?,
                            profile: ProcessAIProfile, key: String?) throws -> URLRequest {
        var url = try resolvedURL(for: profile, key: key)
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessAIError.invalidSettings("Select a model in Settings → AI.")
        }
        let (instruction, context) = try requestText(
            processPath: processPath, parentPath: parentPath,
            applicationName: applicationName, profile: profile
        )
        var body: [String: Any]
        switch profile.provider {
        case .openAICompatible, .ollama:
            body = ["model": profile.model, "stream": false,
                    "messages": [["role": "system", "content": instruction],
                                 ["role": "user", "content": context]]]
        case .anthropic:
            body = ["model": profile.model, "max_tokens": 512, "system": instruction,
                    "messages": [["role": "user", "content": context]]]
        case .gemini:
            let model = profile.model.replacingOccurrences(of: "models/", with: "")
            guard model.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
                throw ProcessAIError.invalidSettings("The Gemini model name contains unsupported characters.")
            }
            url.appendPathComponent("models/\(model):generateContent")
            body = ["systemInstruction": ["parts": [["text": instruction]]],
                    "contents": [["role": "user", "parts": [["text": context]]]]]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch profile.provider {
        case .openAICompatible:
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .ollama: break
        case .anthropic:
            guard let key, !key.isEmpty else { throw ProcessAIError.invalidSettings("Enter an Anthropic API key.") }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            guard let key, !key.isEmpty else { throw ProcessAIError.invalidSettings("Enter a Gemini API key.") }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        return request
    }

    private static func requestText(processPath: String, parentPath: String?, applicationName: String?,
                                    profile: ProcessAIProfile) throws -> (String, String) {
        var language = profile.language
        var customName = profile.customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == .system {
            let code = Locale.preferredLanguages.first?
                .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
            switch code.lowercased() {
            case "ru": language = .russian
            case "en": language = .english
            default:
                language = .custom
                customName = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
            }
        }
        if language == .russian {
            return (
                "Объясни, чем может быть процесс macOS, опираясь только на указанные пути. Ясно обозначь неопределённость и возможную связь с родительским процессом. Не утверждай, что процесс безопасен или опасен, и не выбирай сетевой маршрут. Ответь кратко по-русски.",
                "Исполняемый файл: \(processPath)\nНепосредственный родитель: \(parentPath ?? "неизвестен")\nЗарегистрированная программа: \(applicationName ?? "нет")"
            )
        }
        let english = "Explain what a macOS process may be based only on the supplied paths. State uncertainty clearly. Explain a possible relationship to its parent. Do not claim that it is safe or unsafe and do not choose a network route. Be concise."
        if language == .custom {
            guard !customName.isEmpty, customName.count <= 80,
                  !customName.contains("\n"), !customName.contains("\r") else {
                throw ProcessAIError.invalidSettings("Enter a language name of up to 80 characters.")
            }
        }
        let instruction = language == .custom ? "\(english) Answer in \(customName)." : "\(english) Answer in English."
        return (
            instruction,
            "Executable: \(processPath)\nImmediate parent: \(parentPath ?? "unknown")\nRegistered application: \(applicationName ?? "none")"
        )
    }
}
