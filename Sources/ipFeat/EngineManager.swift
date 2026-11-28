import Foundation

struct EngineRelease: Decodable, Identifiable, Hashable {
    struct Asset: Decodable, Hashable {
        let name: String
        let digest: String?
    }
    let tag_name: String
    let prerelease: Bool
    let body: String?
    let assets: [Asset]

    var version: String { String(tag_name.dropFirst()) }
    var id: String { version }
    var supportsThisMac: Bool {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let name = "sing-box-\(version)-darwin-\(architecture).tar.gz"
        return assets.contains { $0.name == name && $0.digest?.hasPrefix("sha256:") == true }
    }
}

struct EngineHistoryRecord: Decodable, Identifiable {
    let id: UUID
    let date: Date
    let previousVersion: String?
    let version: String
    let releaseChanges: [String]
    let configurationChanges: [String]
    let checksum: String
    let validationOutput: String
    let previousBinaryPath: String?
    let previousSnapshotName: String?
}

private struct EngineStatusRecord: Decodable {
    let activeVersion: String?
    let lastCheck: Date?
    let lastError: String?
}

private struct EnginePolicyRecord: Codable {
    var autoInstall: Bool
    var requestedAt: Date
}

enum LocalSingBoxPatch {
    static let currentPath = "/Library/Application Support/ipFeat/engines/current"
    private static let engineDirectory = "/Library/Application Support/ipFeat/engines"

    static var activeRevision: Int? {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: currentPath)) != nil,
              FileManager.default.isExecutableFile(atPath: currentPath) else { return nil }
        let target = URL(fileURLWithPath: currentPath).resolvingSymlinksInPath().path
        if target == "\(engineDirectory)/1.14.4-ipfeat-8/sing-box" { return 8 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-7/sing-box" { return 7 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-6/sing-box" { return 6 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-5/sing-box" { return 5 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-4/sing-box" { return 4 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-3/sing-box" { return 3 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-2/sing-box" { return 2 }
        if target == "\(engineDirectory)/1.14.4-ipfeat-1/sing-box" { return 1 }
        return nil
    }

    static var isActive: Bool { activeRevision != nil }
}

@MainActor
final class EngineManager: ObservableObject {
    @Published private(set) var releases: [EngineRelease] = []
    @Published private(set) var history: [EngineHistoryRecord] = []
    @Published private(set) var activeVersion: String?
    @Published private(set) var installedVersion: String?
    @Published private(set) var isPatched = false
    @Published private(set) var activePatchRevision: Int?
    @Published private(set) var lastError: String?
    @Published private(set) var message = ""
    @Published private(set) var isInstalling = false
    private var homebrewVersionCache: String?
    private var startedHomebrewVersionLookup = false
    @Published private(set) var preflightOutput = ""
    @Published private(set) var checkedVersion: String?
    @Published var selectedVersion = ""
    @Published var showPrereleases = false
    @Published var autoInstall = false {
        didSet { if autoInstall != oldValue { savePolicy() } }
    }

    private let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ipFeat", isDirectory: true)
    private let systemURL = URL(fileURLWithPath: "/Library/Application Support/ipFeat", isDirectory: true)

    var selectableReleases: [EngineRelease] {
        releases.filter { showPrereleases || !$0.prerelease }
    }

    var canRollback: Bool {
        !isPatched && history.first?.previousVersion != nil && history.first?.previousSnapshotName != nil
    }

    var selectedRelease: EngineRelease? {
        releases.first { $0.version == selectedVersion }
    }

    init() {
        if let data = try? Data(contentsOf: supportURL.appendingPathComponent("engine-policy.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            autoInstall = (try? decoder.decode(EnginePolicyRecord.self, from: data))?.autoInstall ?? false
        }
        refreshLocalState()
    }

    func refreshLocalState() {
        // SwiftUI may construct this object during a view update; keep process checks off the main thread.
        activePatchRevision = LocalSingBoxPatch.activeRevision
        isPatched = activePatchRevision != nil
        if isPatched && autoInstall { autoInstall = false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: systemURL.appendingPathComponent("engine-status.json")),
           let status = try? decoder.decode(EngineStatusRecord.self, from: data) {
            activeVersion = status.activeVersion
            lastError = status.lastError
        }
        if let data = try? Data(contentsOf: systemURL.appendingPathComponent("engine-history.json")),
           let records = try? decoder.decode([EngineHistoryRecord].self, from: data) {
            history = records
        }
        installedVersion = activeVersion ?? homebrewVersionCache
        if selectedVersion.isEmpty { selectedVersion = installedVersion ?? "" }
        if activeVersion == nil && !startedHomebrewVersionLookup {
            startedHomebrewVersionLookup = true
            Task { [weak self] in
                let version = await Task.detached(priority: .utility) { Self.homebrewVersion() }.value
                guard let self else { return }
                self.homebrewVersionCache = version
                self.installedVersion = self.activeVersion ?? version
                if self.selectedVersion.isEmpty { self.selectedVersion = self.installedVersion ?? "" }
            }
        }
    }

    func refreshReleases() async {
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=100")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ipFeat/1", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await releaseData(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "ipFeat", code: 1, userInfo: [NSLocalizedDescriptionKey: AppLanguage.localized("Список выпусков недоступен")])
            }
            releases = try JSONDecoder().decode([EngineRelease].self, from: data)
                .filter { $0.tag_name.hasPrefix("v") && $0.supportsThisMac }
                .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            if selectedVersion.isEmpty {
                selectedVersion = releases.first(where: { !$0.prerelease })?.version ?? ""
            }
            message = "Найдено выпусков: \(releases.count)"
        } catch {
            message = "Не удалось получить выпуски: \(error.localizedDescription)"
        }
    }

    private func releaseData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let sessions = releaseSessions()
        defer { sessions.forEach { $0.invalidateAndCancel() } }
        var lastError: Error?
        for session in sessions {
            do { return try await session.data(for: request) }
            catch { lastError = error }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func releaseSessions() -> [URLSession] {
        let config = supportURL.appendingPathComponent("sing-box.json")
        let root = (try? Data(contentsOf: config))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let ports = root.map(Self.releaseProxyPorts) ?? []
        return (ports.isEmpty ? [nil] : ports.map(Optional.some)).map { port in
            let settings = URLSessionConfiguration.ephemeral
            settings.waitsForConnectivity = false
            if let port {
                settings.connectionProxyDictionary = [
                    "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port
                ]
            }
            return URLSession(configuration: settings)
        }
    }

    static func releaseProxyPorts(in root: [String: Any]) -> [Int] {
        let inbounds = root["inbounds"] as? [[String: Any]] ?? []
        let route = root["route"] as? [String: Any] ?? [:]
        let rules = route["rules"] as? [[String: Any]] ?? []
        func unconditionalOutbound(for tag: String) -> String? {
            rules.first {
                Set($0.keys).isSubset(of: ["inbound", "action", "outbound"]) &&
                ($0["inbound"] as? [String])?.contains(tag) == true &&
                ($0["action"] as? String) == "route"
            }?["outbound"] as? String
        }
        let updaterOutbound = unconditionalOutbound(for: "ipfeat-updater")
            ?? route["final"] as? String
        guard let updaterOutbound else { return [] }
        let candidates = inbounds.filter {
            guard let tag = $0["tag"] as? String,
                  let type = $0["type"] as? String, ["socks", "mixed"].contains(type),
                  ($0["listen"] as? String) == "127.0.0.1",
                  let port = $0["listen_port"] as? Int, (1...65535).contains(port) else { return false }
            if tag == "ipfeat-updater" { return true }
            guard type == "mixed" else { return false }
            let conflictingRule = rules.contains { rule in
                guard (rule["inbound"] as? [String])?.contains(tag) == true else { return false }
                let action = rule["action"] as? String
                return action == "reject" ||
                    (action == "route" && (rule["outbound"] as? String) != updaterOutbound)
            }
            return !conflictingRule &&
                (unconditionalOutbound(for: tag) ?? route["final"] as? String) == updaterOutbound
        }
        let ordered = candidates.sorted {
            ($0["tag"] as? String == "ipfeat-updater") &&
            ($1["tag"] as? String != "ipfeat-updater")
        }
        var ports: [Int] = []
        for inbound in ordered {
            if let port = inbound["listen_port"] as? Int, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    func installSelected() async {
        guard !selectedVersion.isEmpty, !isInstalling else { return }
        guard !isPatched else { message = AppLanguage.localized("Сначала удалите патч ipFeat"); return }
        guard releases.contains(where: { $0.version == selectedVersion }) else {
            message = AppLanguage.localized("Выберите выпуск из списка")
            return
        }
        guard let script = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/install-network-service.sh"),
              FileManager.default.fileExists(atPath: script.path) else {
            message = AppLanguage.localized("Установщик не включён в сборку приложения")
            return
        }
        isInstalling = true
        if selectedRelease?.prerelease == true ||
           selectedVersion != releases.first(where: { !$0.prerelease })?.version {
            autoInstall = false
        }
        message = "Установка \(selectedVersion)…"
        let version = selectedVersion
        let scriptPath = script.path
        let result = await Task.detached(priority: .userInitiated) {
            Self.runPrivilegedInstaller(scriptPath: scriptPath, version: version)
        }.value
        isInstalling = false
        refreshLocalState()
        if result.success {
            message = "sing-box \(version) установлен"
        } else {
            message = result.output.isEmpty ? AppLanguage.localized("Установка отменена или завершилась ошибкой") : result.output
        }
    }

    func checkSelected() async {
        guard let selectedRelease, !isInstalling else { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ipFeatUpdater")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            message = AppLanguage.localized("Проверяющий компонент не включён в сборку")
            return
        }
        isInstalling = true
        message = "Проверка \(selectedRelease.version)…"
        let config = supportURL.appendingPathComponent("sing-box.json").path
        let path = binary.path
        let version = selectedRelease.version
        let result = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--config", config, "--dry-run-version", version]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
            } catch { return (false, error.localizedDescription) }
        }.value
        isInstalling = false
        checkedVersion = result.0 ? version : nil
        preflightOutput = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        message = result.0 ? String(format: AppLanguage.localized("Конфигурация совместима с %@"), version)
                           : AppLanguage.localized("Проверка не прошла")
    }

    func rollback() async {
        guard canRollback, !isInstalling else { return }
        autoInstall = false
        isInstalling = true
        message = AppLanguage.localized("Возврат предыдущей версии…")
        let config = supportURL.appendingPathComponent("sing-box.json").path
        let result = await Task.detached(priority: .userInitiated) {
            let command = "\(Self.shellQuote("/Library/Application Support/ipFeat/ipFeatUpdater")) --config \(Self.shellQuote(config)) --rollback"
            return Self.runPrivileged(command: command)
        }.value
        isInstalling = false
        refreshLocalState()
        message = result.success ? AppLanguage.localized("Предыдущая версия восстановлена") : result.output
    }

    func installPatch() async {
        guard !isInstalling, activePatchRevision != 8 else { return }
        autoInstall = false
        await switchPatch(mode: "--install")
    }

    func removePatch() async {
        guard !isInstalling, isPatched else { return }
        await switchPatch(mode: "--remove")
    }

    private func switchPatch(mode: String) async {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("scripts/install-patched-engine.sh"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            message = AppLanguage.localized("Установщик патча не включён в приложение")
            return
        }
        isInstalling = true
        message = AppLanguage.localized(mode == "--install" ? "Установка патча sing-box…" : "Возврат официального sing-box…")
        let path = script.path
        let result = await Task.detached(priority: .userInitiated) {
            Self.runPrivileged(command: "/bin/zsh \(Self.shellQuote(path)) \(mode)")
        }.value
        isInstalling = false
        refreshLocalState()
        message = result.success ? (mode == "--install" ? "ipFeat sing-box patch 1.14.4-8 installed" : "Official sing-box restored")
            : (result.output.isEmpty ? AppLanguage.localized("Операция отменена или завершилась ошибкой") : result.output)
    }

    private nonisolated static func runPrivilegedInstaller(scriptPath: String, version: String) -> (success: Bool, output: String) {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil else {
            return (false, AppLanguage.localized("Некорректный номер версии"))
        }
        let command = "/bin/zsh \(shellQuote(scriptPath)) --version \(shellQuote(version))"
        return runPrivileged(command: command)
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func runPrivileged(command: String) -> (success: Bool, output: String) {
        let appleScript = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func savePolicy() {
        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(EnginePolicyRecord(autoInstall: autoInstall, requestedAt: Date()))
            try data.write(to: supportURL.appendingPathComponent("engine-policy.json"), options: .atomic)
            message = AppLanguage.localized(autoInstall ? "Автообновление включено; проверка в течение 5 минут" : "Автообновление выключено")
        } catch {
            message = "Не удалось сохранить настройку: \(error.localizedDescription)"
        }
    }

    private nonisolated static func homebrewVersion() -> String? {
        guard let path = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output.split(separator: "\n").first?.split(separator: " ").last.map(String.init)
    }
}
