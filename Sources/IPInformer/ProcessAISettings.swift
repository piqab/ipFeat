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

struct ProcessAIProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var provider: ProcessAIProvider
    var endpoint: String
    var model: String
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
                                       model: profile.model.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.name.isEmpty, !trimmed.model.isEmpty else {
            throw ProcessAIError.invalidSettings("Enter a profile name and model.")
        }
        try ProcessAIClient.validateProfileEndpoint(trimmed, key: key ?? ProcessAIKeychain.load(id: profile.id))
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

    func snapshot() -> ProcessAISettingsSnapshot {
        ProcessAISettingsSnapshot(
            profiles: profiles, selectedProfileID: selectedProfileID,
            keys: Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
                ProcessAIKeychain.load(id: profile.id).map { (profile.id.uuidString, $0) }
            })
        )
    }

    func restore(_ snapshot: ProcessAISettingsSnapshot) throws {
        let oldIDs = Set(profiles.map(\.id))
        let newIDs = Set(snapshot.profiles.map(\.id))
        for id in oldIDs.subtracting(newIDs) { ProcessAIKeychain.delete(id: id) }
        for profile in snapshot.profiles {
            if let key = snapshot.keys[profile.id.uuidString] {
                try ProcessAIKeychain.save(key, id: profile.id)
            } else {
                ProcessAIKeychain.delete(id: profile.id)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        _ = SecItemDelete(query as CFDictionary)
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
        let instruction = "Explain what a macOS process may be based only on the supplied paths. State uncertainty clearly. Explain a possible relationship to its parent. Do not claim that it is safe or unsafe and do not choose a network route. Be concise."
        let context = "Executable: \(processPath)\nImmediate parent: \(parentPath ?? "unknown")\nRegistered application: \(applicationName ?? "none")"
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
}
