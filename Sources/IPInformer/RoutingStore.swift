import AppKit
import Foundation

@MainActor
final class RoutingStore: ObservableObject {
    private static let defaultsKey = "routingConfiguration.v1"
    private static let historyKey = "mainConfigurationHistory.v1"
    static let selfBundleIdentifier = "local.ipinformer.app"

    @Published private(set) var configuration: RoutingConfiguration
    @Published private(set) var interfaces: [NetworkInterfaceOption] = []
    @Published private(set) var outboundTags: [String] = []
    @Published private(set) var generatedConfigPath: String = ""
    @Published private(set) var validationMessage = "Добавьте профиль и программу"
    @Published private(set) var runtimeMessage = "Системная служба ещё не установлена"
    @Published private(set) var applicationActionMessage = ""
    @Published private(set) var configurationHistory: [ConfigurationRevision] = []

    private var connectedIPv4Networks: [LocalIPv4Network] = []
    private var networkTopologyTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(RoutingConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = RoutingConfiguration()
        }
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([ConfigurationRevision].self, from: data) {
            configurationHistory = saved
        }
        if configurationHistory.isEmpty {
            configurationHistory = [ConfigurationRevision(date: Date(), json: configuration.mainConfigurationJSON)]
            saveConfigurationHistory()
        }
        connectedIPv4Networks = NetworkInterfaceProvider.connectedIPv4Networks()
        refreshInterfaces()
        migrateLegacyProfilesIfNeeded()
        configuration = ServerConfigurationCatalog.captureExistingOutbounds(configuration)
        refreshOutboundTags()
        synchronizeProfilesWithOutbounds()
        migrateLegacyWebKitProfileIfNeeded()
        let fallbackTag = outboundTags.first ?? ""
        for index in configuration.profiles.indices
        where configuration.profiles[index].kind == .outbound && configuration.profiles[index].outboundTag.isEmpty {
            configuration.profiles[index].outboundTag = fallbackTag
        }
        ensureSelfApplication()
        persist()
        regenerateConfiguration()
    }

    func refreshInterfaces() {
        interfaces = NetworkInterfaceProvider.availableInterfaces()
    }

    func startNetworkTopologyMonitoring() {
        updateConnectedNetworks()
        networkTopologyTimer?.invalidate()
        networkTopologyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateConnectedNetworks() }
        }
    }

    func stopNetworkTopologyMonitoring() {
        networkTopologyTimer?.invalidate()
        networkTopologyTimer = nil
    }

    private func updateConnectedNetworks() {
        let current = NetworkInterfaceProvider.connectedIPv4Networks()
        guard current != connectedIPv4Networks else { return }
        connectedIPv4Networks = current
        refreshInterfaces()
        regenerateConfiguration()
    }

    func effectiveProfile(for application: RoutedApplication) -> RoutingProfile? {
        guard let id = SingBoxConfigurationGenerator.effectiveProfileID(for: application, configuration: configuration) else {
            return nil
        }
        return configuration.profiles.first { $0.id == id }
    }

    func effectiveOutboundTag(for application: RoutedApplication) -> String? {
        if let profile = effectiveProfile(for: application) {
            return profile.kind == .outbound ? profile.outboundTag.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        guard SingBoxConfigurationGenerator.effectiveProfileID(for: application, configuration: configuration) == nil,
              case .outbound(let tag) = selectedDefaultRoute else { return nil }
        return tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setAlwaysOn(_ enabled: Bool) {
        configuration.singBoxAlwaysOn = enabled
        persistAndRegenerate()
    }

    var selectedDefaultRoute: DefaultRoute {
        SingBoxConfigurationGenerator.defaultRoute(for: configuration)
    }

    func setDefaultRoute(_ route: DefaultRoute) {
        configuration.defaultRoute = route
        persistAndRegenerate()
    }

    var selectedWebKitProfileID: UUID? {
        configuration.webKitProfileID ?? (configuration.webKitProxyEnabled
            ? configuration.profiles.first(where: { $0.kind == .outbound && $0.outboundTag == "proxy" })?.id : nil)
    }

    func setWebKitProfile(_ id: UUID?) {
        if let id {
            guard let profile = configuration.profiles.first(where: { $0.id == id }) else { return }
            if profile.kind == .outbound && !outboundTags.contains(profile.outboundTag) {
                runtimeMessage = "WebKit profile route is unavailable: \(profile.outboundTag)"
                return
            }
        }
        guard configuration.webKitProfileID != id || configuration.webKitProxyEnabled else { return }
        configuration.webKitProfileID = id
        configuration.webKitProxyEnabled = false
        persistAndRegenerate()
    }

    func setAskUnknownProcesses(_ enabled: Bool) {
        guard configuration.askUnknownProcesses != enabled else { return }
        configuration.askUnknownProcesses = enabled
        persistAndRegenerate()
    }

    func addProfile() {
        configuration.profiles.append(RoutingProfile(name: AppLanguage.localized("Новый профиль"),
                                                     outboundTag: outboundTags.first ?? ""))
        persistAndRegenerate()
    }

    @discardableResult
    func applyMainConfigurationJSON(_ json: String) -> Bool {
        var candidate = configuration
        candidate.mainConfigurationJSON = json
        candidate.usesManagedServerConfiguration = false
        do {
            let tags = try SingBoxConfigurationGenerator.outboundTags(in: json)
            if case .outbound(let selectedTag)? = candidate.defaultRoute,
               !tags.contains(selectedTag) {
                candidate.defaultRoute = nil
            }
            // Validate the main sing-box document independently first. This lets
            // the user rename tags and then repair profile assignments, while the
            // service keeps using the last known-good combined file.
            var baseOnlyCandidate = candidate
            baseOnlyCandidate.applications = []
            let baseData = try SingBoxConfigurationGenerator.data(for: baseOnlyCandidate, localNetworks: connectedIPv4Networks)
            if singBoxBinaryPath() != nil { try validateWithSingBox(baseData) }
            configuration = candidate
            outboundTags = tags
            synchronizeProfilesWithOutbounds()
            ensureSelfApplication()
            persist()
            regenerateConfiguration()
            if configurationHistory.first?.json != json {
                configurationHistory.insert(ConfigurationRevision(date: Date(), json: json), at: 0)
                configurationHistory = Array(configurationHistory.prefix(30))
                saveConfigurationHistory()
            }
            runtimeMessage = validationMessage.hasPrefix("Конфигурация готова")
                ? "Основная конфигурация применена"
                : "Основная конфигурация сохранена; исправьте назначения профилей"
            return true
        } catch {
            runtimeMessage = error.localizedDescription
            return false
        }
    }

    var serverConfigurationMigration: ServerConfigurationCatalog.MigrationReport {
        ServerConfigurationCatalog.report(configuration)
    }

    func previewManagedServerConfiguration() throws -> String {
        try ServerConfigurationCatalog.managedJSON(for: configuration)
    }

    func adoptSavedServerConfiguration(replacementTag: String? = nil) throws {
        guard !configuration.usesManagedServerConfiguration else { return }
        let report = serverConfigurationMigration
        guard report.missingConnections.isEmpty else {
            throw RoutingConfigurationError.invalidMainConfiguration("Restore missing client outbounds first")
        }
        var candidate = configuration
        let previousJSON = candidate.mainConfigurationJSON
        let retainedTags = Set(candidate.clientConnections.map(\.outboundTag)).union(["direct"])
        if !report.unresolvedRoutes.isEmpty {
            guard let replacementTag, retainedTags.contains(replacementTag) else {
                throw RoutingConfigurationError.invalidMainConfiguration("Choose a saved server or direct for unavailable routes")
            }
            candidate = try ServerConfigurationCatalog.reassignUnavailableRoutes(candidate, to: replacementTag)
        }
        candidate.mainConfigurationJSON = try ServerConfigurationCatalog.managedJSON(for: candidate)
        candidate.usesManagedServerConfiguration = true
        if candidate.defaultRoute == nil {
            let oldFinal = (try? JSONSerialization.jsonObject(with: Data(previousJSON.utf8)))
                .flatMap { $0 as? [String: Any] }
                .flatMap { $0["route"] as? [String: Any] }?["final"] as? String
            candidate.defaultRoute = .outbound(oldFinal.flatMap { retainedTags.contains($0) ? $0 : nil }
                ?? replacementTag ?? "direct")
        }
        let generated = try SingBoxConfigurationGenerator.data(for: candidate, localNetworks: connectedIPv4Networks)
        if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
        configuration = candidate
        outboundTags = try SingBoxConfigurationGenerator.outboundTags(in: candidate.mainConfigurationJSON)
        persistAndRegenerate()
        recordConfigurationChange(from: previousJSON)
        runtimeMessage = "Saved server connections now generate the sing-box configuration"
    }

    func restoreClientOutbound(_ id: UUID, json: String) throws {
        guard let index = configuration.clientConnections.firstIndex(where: { $0.id == id }),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw RoutingConfigurationError.invalidMainConfiguration("Client outbound tag does not match this connection")
        }
        let tag = configuration.clientConnections[index].outboundTag
        let outbound = root["tag"] as? String == tag ? root :
            (root["outbounds"] as? [[String: Any]])?.first(where: { $0["tag"] as? String == tag })
        guard let outbound,
              let data = try? JSONSerialization.data(withJSONObject: outbound, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw RoutingConfigurationError.invalidMainConfiguration("Client outbound tag does not match this connection")
        }
        var candidate = configuration
        candidate.clientConnections[index].outboundJSON = String(decoding: data, as: UTF8.self)
        if candidate.usesManagedServerConfiguration {
            candidate.mainConfigurationJSON = try ServerConfigurationCatalog.managedJSON(for: candidate)
            let generated = try SingBoxConfigurationGenerator.data(for: candidate, localNetworks: connectedIPv4Networks)
            if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
        }
        let previousJSON = configuration.mainConfigurationJSON
        configuration = candidate
        persistAndRegenerate()
        recordConfigurationChange(from: previousJSON)
    }

    private func recordConfigurationChange(from previousJSON: String) {
        guard previousJSON != configuration.mainConfigurationJSON else { return }
        configurationHistory.insert(ConfigurationRevision(date: Date(), json: configuration.mainConfigurationJSON), at: 0)
        configurationHistory = Array(configurationHistory.prefix(30))
        saveConfigurationHistory()
    }

    func importMainConfiguration(from url: URL) {
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            if applyMainConfigurationJSON(json) {
                runtimeMessage = "Импортирован файл \(url.lastPathComponent)"
            }
        } catch {
            runtimeMessage = "Не удалось прочитать конфигурацию: \(error.localizedDescription)"
        }
    }

    func registerClientConnection(_ connection: ClientConnection, outboundJSON: String,
                                  serverConfiguration: String) throws {
        guard let data = outboundJSON.data(using: .utf8),
              let outbound = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (outbound["tag"] as? String) == connection.outboundTag,
              (outbound["type"] as? String) == connection.protocolName else {
            throw RoutingConfigurationError.invalidMainConfiguration("Клиентский outbound не совпадает с выбранным подключением")
        }
        guard !outboundTags.contains(connection.outboundTag) else {
            throw RoutingConfigurationError.invalidMainConfiguration("Тег \(connection.outboundTag) уже используется")
        }
        var storedConnection = connection
        storedConnection.outboundJSON = outboundJSON
        let hadNamedRoute = configuration.profiles.contains {
            $0.kind == .outbound && $0.outboundTag == connection.outboundTag
        }
        if configuration.usesManagedServerConfiguration {
            var candidate = configuration
            candidate.clientConnections.append(storedConnection)
            candidate.mainConfigurationJSON = try ServerConfigurationCatalog.managedJSON(for: candidate)
            let generated = try SingBoxConfigurationGenerator.data(for: candidate, localNetworks: connectedIPv4Networks)
            if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
            try ServerSecretStore.save(serverConfiguration, id: connection.id)
            let previousJSON = configuration.mainConfigurationJSON
            configuration = candidate
            outboundTags = try SingBoxConfigurationGenerator.outboundTags(in: candidate.mainConfigurationJSON)
            synchronizeProfilesWithOutbounds()
            if !hadNamedRoute, let index = configuration.profiles.firstIndex(where: {
                $0.kind == .outbound && $0.outboundTag == connection.outboundTag
            }) {
                configuration.profiles[index].name = connection.name
            }
            persistAndRegenerate()
            recordConfigurationChange(from: previousJSON)
            return
        }
        let previousJSON = configuration.mainConfigurationJSON
        guard let rootData = previousJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any] else {
            throw RoutingConfigurationError.invalidMainConfiguration("Основной JSON повреждён")
        }
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        outbounds.append(outbound)
        root["outbounds"] = outbounds
        let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let updatedJSON = String(data: updatedData, encoding: .utf8) else {
            throw RoutingConfigurationError.invalidMainConfiguration("Не удалось записать клиентский JSON")
        }
        try previewClientConnection(connection, outboundJSON: outboundJSON)
        try ServerSecretStore.save(serverConfiguration, id: connection.id)
        guard applyMainConfigurationJSON(updatedJSON), validationMessage.hasPrefix("Конфигурация готова") else {
            let failure = validationMessage
            ServerSecretStore.delete(id: connection.id)
            if configuration.mainConfigurationJSON != previousJSON { _ = applyMainConfigurationJSON(previousJSON) }
            throw RoutingConfigurationError.invalidMainConfiguration(failure)
        }
        configuration.clientConnections.append(storedConnection)
        if !hadNamedRoute, let index = configuration.profiles.firstIndex(where: {
            $0.kind == .outbound && $0.outboundTag == connection.outboundTag
        }) {
            configuration.profiles[index].name = connection.name
        }
        persistAndRegenerate()
    }

    func completePendingServerInstallation(_ pending: PendingServerInstallation, result: String) throws {
        guard pending.accepts(result) else {
            throw RoutingConfigurationError.invalidMainConfiguration("Installation result does not match this server, version and configuration")
        }
        if configuration.clientConnections.contains(where: { $0.id == pending.id }) {
            PendingServerInstallationStore.remove(pending.id)
            return
        }
        var connection = ClientConnection(id: pending.id, name: pending.name,
            outboundTag: pending.outboundTag, serverIPv4: pending.serverIPv4,
            protocolName: pending.protocolName, singBoxVersion: pending.version)
        connection.serverArchitecture = pending.architecture
        connection.serverSSHPort = pending.sshPort
        connection.installationVerified = false
        try previewClientConnection(connection, outboundJSON: pending.clientJSON)
        try registerClientConnection(connection, outboundJSON: pending.clientJSON,
                                     serverConfiguration: pending.serverJSON)
        PendingServerInstallationStore.remove(pending.id)
    }

    func updateServerInstallation(_ id: UUID, verified: Bool, architecture: String?, sshPort: Int) {
        guard let index = configuration.clientConnections.firstIndex(where: { $0.id == id }) else { return }
        configuration.clientConnections[index].installationVerified = verified
        configuration.clientConnections[index].installationCheckedAt = Date()
        configuration.clientConnections[index].serverArchitecture = architecture
        configuration.clientConnections[index].serverSSHPort = sshPort
        persist()
    }

    func previewClientConnection(_ connection: ClientConnection, outboundJSON: String) throws {
        guard let rootData = configuration.mainConfigurationJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              let outbound = try JSONSerialization.jsonObject(with: Data(outboundJSON.utf8)) as? [String: Any],
              (outbound["tag"] as? String) == connection.outboundTag,
              (outbound["type"] as? String) == connection.protocolName,
              !outboundTags.contains(connection.outboundTag) else {
            throw RoutingConfigurationError.invalidMainConfiguration("Клиентский outbound или его тег некорректен")
        }
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        outbounds.append(outbound)
        root["outbounds"] = outbounds
        var candidate = configuration
        candidate.mainConfigurationJSON = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        let generated = try SingBoxConfigurationGenerator.data(for: candidate, localNetworks: connectedIPv4Networks)
        if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
    }

    func activateClientConnection(_ id: UUID) {
        guard let connection = configuration.clientConnections.first(where: { $0.id == id }),
              outboundTags.contains(connection.outboundTag) else { return }
        setDefaultRoute(.outbound(connection.outboundTag))
    }

    func previewClientRemoval(_ id: UUID, replacementProfileID: UUID) throws {
        _ = try preparedClientRemoval(id, replacementProfileID: replacementProfileID)
    }

    func rerouteBeforeServerRemoval(_ id: UUID, replacementProfileID: UUID) throws {
        let candidate = try ClientConnectionRemoval.reroute(configuration, id: id,
                                                            replacementProfileID: replacementProfileID)
        let generated = try SingBoxConfigurationGenerator.data(for: candidate, localNetworks: connectedIPv4Networks)
        if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
        configuration = candidate
        persistAndRegenerate()
        runtimeMessage = "Маршрут IP Informer переключён перед удалением сервера"
    }

    func removeClientConnection(_ id: UUID, replacementProfileID: UUID) throws {
        var candidate = try preparedClientRemoval(id, replacementProfileID: replacementProfileID)
        if candidate.usesManagedServerConfiguration {
            candidate.mainConfigurationJSON = try ServerConfigurationCatalog.managedJSON(for: candidate)
        }
        let updatedTags = try SingBoxConfigurationGenerator.outboundTags(in: candidate.mainConfigurationJSON)
        try ServerSecretStore.deleteChecked(id: id)
        let previousJSON = configuration.mainConfigurationJSON
        configuration = candidate
        outboundTags = updatedTags
        persistAndRegenerate()
        if previousJSON != candidate.mainConfigurationJSON {
            configurationHistory.insert(ConfigurationRevision(date: Date(), json: candidate.mainConfigurationJSON), at: 0)
            configurationHistory = Array(configurationHistory.prefix(30))
            saveConfigurationHistory()
        }
        runtimeMessage = "Клиентское подключение удалено"
    }

    private func preparedClientRemoval(_ id: UUID, replacementProfileID: UUID) throws -> RoutingConfiguration {
        var candidate = try ClientConnectionRemoval.prepare(configuration, id: id,
                                                            replacementProfileID: replacementProfileID)
        if candidate.usesManagedServerConfiguration {
            candidate.mainConfigurationJSON = try ServerConfigurationCatalog.managedJSON(for: candidate)
        }
        let generated = try SingBoxConfigurationGenerator.data(for: candidate, localNetworks: connectedIPv4Networks)
        if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
        return candidate
    }

    func restoreConfiguration(_ restored: RoutingConfiguration, history: [ConfigurationRevision]) throws -> [String] {
        var prepared = Self.prepareRestoredConfiguration(restored)
        prepared.configuration = ServerConfigurationCatalog.captureExistingOutbounds(prepared.configuration)
        if prepared.configuration.usesManagedServerConfiguration {
            prepared.configuration.mainConfigurationJSON = try ServerConfigurationCatalog.managedJSON(for: prepared.configuration)
        }
        let tags = try SingBoxConfigurationGenerator.outboundTags(in: prepared.configuration.mainConfigurationJSON)
        let generated = try SingBoxConfigurationGenerator.data(for: prepared.configuration, localNetworks: connectedIPv4Networks)
        if singBoxBinaryPath() != nil { try validateWithSingBox(generated) }
        configuration = prepared.configuration
        outboundTags = tags
        synchronizeProfilesWithOutbounds()
        migrateLegacyWebKitProfileIfNeeded()
        ensureSelfApplication()
        persistAndRegenerate()
        configurationHistory = Array(history.prefix(30))
        if configurationHistory.first?.json != configuration.mainConfigurationJSON {
            configurationHistory.insert(ConfigurationRevision(date: Date(), json: configuration.mainConfigurationJSON), at: 0)
            configurationHistory = Array(configurationHistory.prefix(30))
        }
        saveConfigurationHistory()
        return prepared.missingApplications
    }

    static func prepareRestoredConfiguration(_ original: RoutingConfiguration) -> (configuration: RoutingConfiguration, missingApplications: [String]) {
        var restored = original
        var missing: [String] = []
        for index in restored.clientConnections.indices {
            restored.clientConnections[index].installationVerified = nil
            restored.clientConnections[index].installationCheckedAt = nil
        }
        for index in restored.applications.indices {
            let app = restored.applications[index]
            if app.bundleIdentifier == selfBundleIdentifier {
                if Bundle.main.bundleIdentifier == selfBundleIdentifier,
                   let executable = Bundle.main.executableURL {
                    restored.applications[index].bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
                    restored.applications[index].executablePath = executable.standardizedFileURL.path
                }
                continue
            }
            let originalURL = URL(fileURLWithPath: app.bundlePath)
            let matchingOriginal = Bundle(url: originalURL).flatMap { bundle -> URL? in
                bundle.bundleIdentifier == app.bundleIdentifier && bundle.executableURL != nil ? originalURL : nil
            }
            let found = matchingOriginal ?? app.bundleIdentifier.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }
            if let found, let bundle = Bundle(url: found),
               bundle.bundleIdentifier == app.bundleIdentifier,
               let executable = bundle.executableURL {
                restored.applications[index].bundlePath = found.standardizedFileURL.path
                restored.applications[index].executablePath = executable.standardizedFileURL.path
            } else {
                restored.applications[index].enabled = false
                missing.append(app.name)
            }
        }
        for index in restored.commands.indices where restored.commands[index].enabled {
            let command = restored.commands[index]
            if !FileManager.default.isExecutableFile(atPath: command.executablePath) {
                restored.commands[index].enabled = false
                missing.append("Command: \(command.name)")
            }
        }
        for index in restored.savedProcessRoutes.indices where restored.savedProcessRoutes[index].enabled {
            let route = restored.savedProcessRoutes[index]
            if !FileManager.default.isExecutableFile(atPath: route.executablePath) {
                restored.savedProcessRoutes[index].enabled = false
                missing.append("Saved route: \(URL(fileURLWithPath: route.executablePath).lastPathComponent)")
            }
        }
        return (restored, missing)
    }

    func relinkApplication(_ application: RoutedApplication, to url: URL) -> String? {
        guard let bundle = Bundle(url: url), let executable = bundle.executableURL else {
            return "Не удалось открыть выбранную .app"
        }
        guard application.bundleIdentifier == nil || bundle.bundleIdentifier == application.bundleIdentifier else {
            return "Идентификатор выбранной программы не совпадает"
        }
        guard let index = configuration.applications.firstIndex(where: { $0.id == application.id }) else {
            return "Программа не найдена"
        }
        let canonicalPath = url.resolvingSymlinksInPath().path
        guard !configuration.applications.contains(where: {
            $0.id != application.id && URL(fileURLWithPath: $0.bundlePath).resolvingSymlinksInPath().path == canonicalPath
        }) else {
            return "Эта программа уже находится в списке"
        }
        configuration.applications[index].bundlePath = url.standardizedFileURL.path
        configuration.applications[index].executablePath = executable.standardizedFileURL.path
        configuration.applications[index].bundleIdentifier = bundle.bundleIdentifier
        configuration.applications[index].enabled = true
        persistAndRegenerate()
        return nil
    }

    func updateProfile(_ profile: RoutingProfile) {
        guard let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        configuration.profiles[index] = profile
        persistAndRegenerate()
    }

    func removeProfile(_ profile: RoutingProfile) {
        guard !profile.isBuiltIn else { return }
        configuration.profiles.removeAll { $0.id == profile.id }
        if configuration.webKitProfileID == profile.id { configuration.webKitProfileID = nil }
        for index in configuration.groups.indices where configuration.groups[index].profileID == profile.id {
            configuration.groups[index].profileID = nil
        }
        for index in configuration.applications.indices where configuration.applications[index].profileID == profile.id {
            configuration.applications[index].profileID = nil
        }
        for index in configuration.commands.indices where configuration.commands[index].profileID == profile.id {
            configuration.commands[index].profileID = nil
        }
        persistAndRegenerate()
    }

    func addCommands(at urls: [URL]) -> [String] {
        var errors: [String] = []
        var known = Set(configuration.commands.map {
            URL(fileURLWithPath: $0.executablePath).resolvingSymlinksInPath().path
        })
        var added: [RoutedCommand] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix("/"), !path.contains(".app/"),
                  FileManager.default.isExecutableFile(atPath: path) else {
                errors.append("\(url.lastPathComponent): выберите исполняемый файл команды, а не .app")
                continue
            }
            let canonical = url.resolvingSymlinksInPath().path
            guard !known.contains(canonical) else { continue }
            known.insert(canonical)
            added.append(RoutedCommand(name: url.lastPathComponent, executablePath: path))
        }
        if !added.isEmpty {
            configuration.commands.append(contentsOf: added)
            persistAndRegenerate()
        }
        return errors
    }

    func updateCommand(_ command: RoutedCommand) {
        guard let index = configuration.commands.firstIndex(where: { $0.id == command.id }) else { return }
        configuration.commands[index] = command
        persistAndRegenerate()
    }

    func removeCommand(_ command: RoutedCommand) {
        configuration.commands.removeAll { $0.id == command.id }
        persistAndRegenerate()
    }

    func removeCommands(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        configuration.commands.removeAll { ids.contains($0.id) }
        persistAndRegenerate()
    }

    func relinkCommand(_ command: RoutedCommand, to url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard !path.contains(".app/"), FileManager.default.isExecutableFile(atPath: path) else {
            return "Выберите исполняемый файл команды"
        }
        let canonical = url.resolvingSymlinksInPath().path
        guard !configuration.commands.contains(where: {
            $0.id != command.id && URL(fileURLWithPath: $0.executablePath).resolvingSymlinksInPath().path == canonical
        }) else { return "Эта команда уже добавлена" }
        guard let index = configuration.commands.firstIndex(where: { $0.id == command.id }) else {
            return "Команда не найдена"
        }
        configuration.commands[index].executablePath = path
        configuration.commands[index].name = url.lastPathComponent
        configuration.commands[index].enabled = true
        persistAndRegenerate()
        return nil
    }

    func addGroup() {
        configuration.groups.insert(RoutingGroup(id: UUID(), name: AppLanguage.localized("Новая группа"), profileID: nil), at: 0)
        persistAndRegenerate()
    }

    func updateGroup(_ group: RoutingGroup) {
        guard let index = configuration.groups.firstIndex(where: { $0.id == group.id }) else { return }
        configuration.groups[index] = group
        persistAndRegenerate()
    }

    func removeGroup(_ group: RoutingGroup) {
        configuration.groups.removeAll { $0.id == group.id }
        for index in configuration.applications.indices where configuration.applications[index].groupID == group.id {
            configuration.applications[index].groupID = nil
        }
        for index in configuration.savedProcessRoutes.indices where configuration.savedProcessRoutes[index].groupID == group.id {
            configuration.savedProcessRoutes[index].groupID = nil
        }
        persistAndRegenerate()
    }

    func addApplications(at urls: [URL], toGroup groupID: UUID?) -> [String] {
        guard groupID == nil || configuration.groups.contains(where: { $0.id == groupID }) else {
            return ["Группа не найдена"]
        }
        let planned = Self.planApplicationImports(urls, existing: configuration.applications, groupID: groupID)
        if !planned.applications.isEmpty {
            configuration.applications.append(contentsOf: planned.applications)
            persistAndRegenerate()
        }
        return planned.errors
    }

    static func planApplicationImports(
        _ urls: [URL], existing: [RoutedApplication], groupID: UUID?
    ) -> (applications: [RoutedApplication], errors: [String]) {
        var errors: [String] = []
        var additions: [RoutedApplication] = []
        var knownPaths = Set(existing.map { URL(fileURLWithPath: $0.bundlePath).resolvingSymlinksInPath().path })
        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url),
                  bundle.bundleURL.standardizedFileURL == url.standardizedFileURL,
                  let executableURL = bundle.executableURL else {
                errors.append("\(url.lastPathComponent): не удалось определить исполняемый файл .app")
                continue
            }
            let canonicalPath = url.resolvingSymlinksInPath().path
            let bundleID = bundle.bundleIdentifier
            if knownPaths.contains(canonicalPath)
                || (bundleID == Self.selfBundleIdentifier && (existing + additions).contains { $0.bundleIdentifier == Self.selfBundleIdentifier }) {
                continue
            }
            knownPaths.insert(canonicalPath)
            additions.append(RoutedApplication(
                id: UUID(),
                name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent,
                bundlePath: standardizedPath,
                executablePath: executableURL.standardizedFileURL.path,
                bundleIdentifier: bundleID,
                groupID: groupID,
                profileID: nil,
                enabled: true,
                launchAfterEngineReady: false,
                askChildCommands: true
            ))
        }
        return (additions, errors)
    }

    func updateApplication(_ application: RoutedApplication) {
        guard let index = configuration.applications.firstIndex(where: { $0.id == application.id }) else { return }
        configuration.applications[index] = application
        if application.bundleIdentifier == Self.selfBundleIdentifier {
            configuration.selfProxySeeded = true
        }
        persistAndRegenerate()
    }

    func removeApplication(_ application: RoutedApplication) {
        guard application.bundleIdentifier != Self.selfBundleIdentifier else { return }
        configuration.applications.removeAll { $0.id == application.id }
        configuration.childCommandChoices.removeAll { $0.applicationID == application.id }
        configuration.redirects.removeAll { $0.applicationID == application.id }
        persistAndRegenerate()
    }

    func saveChildCommandChoice(applicationID: UUID, executablePath: String, route: DefaultRoute) {
        guard configuration.applications.contains(where: { $0.id == applicationID && $0.askChildCommands }) else { return }
        let path = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        guard path.hasPrefix("/"), !path.contains("\n") else { return }
        if let index = configuration.childCommandChoices.firstIndex(where: {
            $0.applicationID == applicationID && $0.executablePath == path
        }) {
            configuration.childCommandChoices[index].route = route
        } else {
            configuration.childCommandChoices.append(ChildCommandChoice(applicationID: applicationID,
                                                                        executablePath: path, route: route))
        }
        persistAndRegenerate()
    }

    func removeChildCommandChoice(_ choice: ChildCommandChoice) {
        configuration.childCommandChoices.removeAll { $0.id == choice.id }
        persistAndRegenerate()
    }

    func saveProcessRoute(executablePath: String, route: DefaultRoute) {
        let path = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        guard path.hasPrefix("/"), !path.contains("\n"),
              !configuration.applications.contains(where: { $0.executablePath == path }),
              !configuration.commands.contains(where: { $0.executablePath == path }) else { return }
        if let index = configuration.savedProcessRoutes.firstIndex(where: { $0.executablePath == path }) {
            configuration.savedProcessRoutes[index].route = route
            configuration.savedProcessRoutes[index].enabled = true
        } else {
            configuration.savedProcessRoutes.append(SavedProcessRoute(executablePath: path, route: route))
        }
        persistAndRegenerate()
    }

    func updateProcessRoutes(ids: Set<UUID>, groupID: UUID? = nil, route: DefaultRoute? = nil,
                             remove: Bool = false) {
        guard !ids.isEmpty else { return }
        if remove {
            configuration.savedProcessRoutes.removeAll { ids.contains($0.id) }
        } else {
            guard groupID == nil || configuration.groups.contains(where: { $0.id == groupID }) else { return }
            for index in configuration.savedProcessRoutes.indices where ids.contains(configuration.savedProcessRoutes[index].id) {
                if let route { configuration.savedProcessRoutes[index].route = route }
                else { configuration.savedProcessRoutes[index].groupID = groupID }
            }
        }
        persistAndRegenerate()
    }

    func setProcessRouteEnabled(_ id: UUID, enabled: Bool) {
        guard let index = configuration.savedProcessRoutes.firstIndex(where: { $0.id == id }),
              !enabled || FileManager.default.isExecutableFile(atPath: configuration.savedProcessRoutes[index].executablePath) else { return }
        configuration.savedProcessRoutes[index].enabled = enabled
        persistAndRegenerate()
    }

    func relinkProcessRoute(_ id: UUID, to url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path),
              !configuration.savedProcessRoutes.contains(where: { $0.id != id && $0.executablePath == path }) else {
            return "Choose a unique executable file."
        }
        guard let index = configuration.savedProcessRoutes.firstIndex(where: { $0.id == id }) else {
            return "Saved route no longer exists."
        }
        configuration.savedProcessRoutes[index].executablePath = path
        configuration.savedProcessRoutes[index].enabled = true
        persistAndRegenerate()
        return nil
    }

    func updateCategoryItems(applicationIDs: Set<UUID>, processRouteIDs: Set<UUID>,
                             groupID: UUID?, remove: Bool) {
        guard !applicationIDs.isEmpty || !processRouteIDs.isEmpty else { return }
        guard remove || groupID == nil || configuration.groups.contains(where: { $0.id == groupID }) else { return }
        let protectedIDs = Set(configuration.applications.filter {
            $0.bundleIdentifier == Self.selfBundleIdentifier
        }.map(\.id))
        let removableApps = applicationIDs.subtracting(protectedIDs)
        if remove {
            configuration.applications.removeAll { removableApps.contains($0.id) }
            configuration.childCommandChoices.removeAll { removableApps.contains($0.applicationID) }
            configuration.redirects.removeAll { $0.applicationID.map(removableApps.contains) == true }
            configuration.savedProcessRoutes.removeAll { processRouteIDs.contains($0.id) }
        } else {
            for index in configuration.applications.indices where applicationIDs.contains(configuration.applications[index].id) {
                configuration.applications[index].groupID = groupID
            }
            for index in configuration.savedProcessRoutes.indices where processRouteIDs.contains(configuration.savedProcessRoutes[index].id) {
                configuration.savedProcessRoutes[index].groupID = groupID
            }
        }
        persistAndRegenerate()
    }

    func addRedirect() {
        configuration.redirects.append(ApplicationRedirect(
            id: UUID(), applicationID: configuration.applications.first?.id,
            sourceDomain: "example.com", sourcePort: 443,
            targetAddress: "127.0.0.1", targetPort: 443, enabled: true
        ))
        persistAndRegenerate()
    }

    func updateRedirect(_ redirect: ApplicationRedirect) {
        guard let index = configuration.redirects.firstIndex(where: { $0.id == redirect.id }) else { return }
        configuration.redirects[index] = redirect
        persistAndRegenerate()
    }

    func removeRedirect(_ redirect: ApplicationRedirect) {
        configuration.redirects.removeAll { $0.id == redirect.id }
        persistAndRegenerate()
    }

    func saveDomainRule(_ rule: DomainRouteRule) throws {
        _ = try rule.matchFields()
        guard outboundTags.contains(rule.outboundTag) else {
            throw RoutingConfigurationError.unknownOutbound(rule.outboundTag)
        }
        guard !configuration.domainRules.contains(where: {
            $0.id != rule.id && $0.normalizedPattern == rule.normalizedPattern
        }) else {
            throw RoutingConfigurationError.invalidMainConfiguration("Domain pattern already exists: \(rule.pattern)")
        }
        if let index = configuration.domainRules.firstIndex(where: { $0.id == rule.id }) {
            configuration.domainRules[index] = rule
        } else {
            configuration.domainRules.append(rule)
        }
        persistAndRegenerate()
    }

    func setDomainRuleEnabled(_ id: UUID, enabled: Bool) {
        guard let index = configuration.domainRules.firstIndex(where: { $0.id == id }) else { return }
        guard !enabled || outboundTags.contains(configuration.domainRules[index].outboundTag) else { return }
        configuration.domainRules[index].enabled = enabled
        persistAndRegenerate()
    }

    func removeDomainRule(_ id: UUID) {
        configuration.domainRules.removeAll { $0.id == id }
        persistAndRegenerate()
    }

    func launch(_ application: RoutedApplication) {
        guard application.enabled else {
            applicationActionMessage = "Сначала включите \(application.name): её профиль сейчас не применяется"
            return
        }
        let selectedPath = URL(fileURLWithPath: application.bundlePath).standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == selectedPath
        }) ?? application.bundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
        if let running {
            let activated = running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            applicationActionMessage = activated ? "\(application.name) открыта" : "Не удалось переключиться на \(application.name)"
            return
        }
        guard validationMessage.hasPrefix("Конфигурация готова") else {
            applicationActionMessage = "Сначала исправьте конфигурацию маршрутизации"
            return
        }
        guard FileManager.default.fileExists(atPath: application.bundlePath) else {
            applicationActionMessage = "Программа больше не найдена: \(application.bundlePath)"
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: application.bundlePath), configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                self?.applicationActionMessage = error == nil ? "\(application.name) запущена" : "Ошибка запуска: \(error!.localizedDescription)"
            }
        }
    }

    func validateWithInstalledSingBox() {
        guard !generatedConfigPath.isEmpty else {
            runtimeMessage = "Нет готовой конфигурации"
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: generatedConfigPath))
            try validateWithSingBox(data)
            runtimeMessage = "sing-box: конфигурация корректна"
        } catch {
            runtimeMessage = error.localizedDescription
        }
    }

    func reportRuntimeError(_ message: String) {
        runtimeMessage = message
    }

    private func persistAndRegenerate() {
        persist()
        regenerateConfiguration()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func saveConfigurationHistory() {
        if let data = try? JSONEncoder().encode(configurationHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func ensureSelfApplication() {
        guard Bundle.main.bundleIdentifier == Self.selfBundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app",
              let executableURL = Bundle.main.executableURL else { return }
        Self.ensureSelfApplication(in: &configuration, bundleURL: Bundle.main.bundleURL, executableURL: executableURL)
    }

    static func ensureSelfApplication(
        in configuration: inout RoutingConfiguration, bundleURL: URL, executableURL: URL
    ) {
        let bundlePath = bundleURL.standardizedFileURL.path
        let executablePath = executableURL.standardizedFileURL.path
        if let index = configuration.applications.firstIndex(where: { $0.bundleIdentifier == Self.selfBundleIdentifier }) {
            configuration.applications[index].bundlePath = bundlePath
            configuration.applications[index].executablePath = executablePath
            if configuration.applications[index].profileID != nil || configuration.applications[index].groupID != nil {
                configuration.selfProxySeeded = true
            } else if !configuration.selfProxySeeded,
               let proxyProfile = configuration.profiles.first(where: { $0.kind == .outbound && $0.outboundTag == "proxy" }) {
                configuration.applications[index].profileID = proxyProfile.id
                configuration.selfProxySeeded = true
            }
            return
        }
        let proxyProfileID = configuration.profiles.first {
            $0.kind == .outbound && $0.outboundTag == "proxy"
        }?.id
        configuration.applications.insert(RoutedApplication(
            id: UUID(), name: "IP Informer", bundlePath: bundlePath,
            executablePath: executablePath, bundleIdentifier: Self.selfBundleIdentifier,
            groupID: nil, profileID: proxyProfileID, enabled: true,
            launchAfterEngineReady: false
        ), at: 0)
        configuration.selfProxySeeded = proxyProfileID != nil
    }

    private func refreshOutboundTags() {
        outboundTags = (try? SingBoxConfigurationGenerator.outboundTags(in: configuration.mainConfigurationJSON)) ?? []
    }

    private func synchronizeProfilesWithOutbounds() {
        let builtIns: [RoutingProfile] = [.block, .localOnly, .localNetwork]
        for profile in builtIns where !configuration.profiles.contains(where: { $0.id == profile.id }) {
            configuration.profiles.insert(profile, at: 0)
        }
        for tag in outboundTags where !configuration.profiles.contains(where: { $0.kind == .outbound && $0.outboundTag == tag }) {
            configuration.profiles.append(RoutingProfile(name: tag, outboundTag: tag))
        }
    }

    private func migrateLegacyWebKitProfileIfNeeded() {
        guard configuration.webKitProxyEnabled, configuration.webKitProfileID == nil,
              let profile = configuration.profiles.first(where: { $0.kind == .outbound && $0.outboundTag == "proxy" }) else { return }
        configuration.webKitProfileID = profile.id
        configuration.webKitProxyEnabled = false
    }

    private func migrateLegacyProfilesIfNeeded() {
        guard configuration.profiles.contains(where: { $0.outboundTag.isEmpty && $0.legacyOutboundJSON != nil }),
              let data = configuration.mainConfigurationJSON.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        for index in configuration.profiles.indices {
            guard configuration.profiles[index].outboundTag.isEmpty,
                  let legacyJSON = configuration.profiles[index].legacyOutboundJSON,
                  let legacyData = legacyJSON.data(using: .utf8),
                  var outbound = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any] else { continue }
            let tag = "profile-\(configuration.profiles[index].id.uuidString.lowercased())"
            outbound["tag"] = tag
            if let interface = configuration.profiles[index].legacyInterfaceName, !interface.isEmpty {
                outbound["bind_interface"] = interface
            }
            outbounds.append(outbound)
            configuration.profiles[index].outboundTag = tag
            configuration.profiles[index].legacyInterfaceName = nil
            configuration.profiles[index].legacyOutboundJSON = nil
        }
        root["outbounds"] = outbounds
        if let migrated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let json = String(data: migrated, encoding: .utf8) {
            configuration.mainConfigurationJSON = json
        }
    }

    private func regenerateConfiguration() {
        do {
            let data = try SingBoxConfigurationGenerator.data(for: configuration, localNetworks: connectedIPv4Networks)
            let live = try SingBoxConfigurationGenerator.liveConfiguration(for: configuration,
                                                                            localNetworks: connectedIPv4Networks)
            if singBoxBinaryPath() != nil { try validateWithSingBox(data) }
            if isPatchedSingBox { try validateWithSingBox(live.base, policy: live.policy) }
            let directory = try applicationSupportDirectory()
            try writeIfChanged(live.policy, to: directory.appendingPathComponent("sing-box-policy.json"))
            try writeIfChanged(live.base, to: directory.appendingPathComponent("sing-box-base.json"))
            try writeGeneratedConfiguration(data)
            validationMessage = singBoxBinaryPath() == nil
                ? "Конфигурация создана · установите sing-box для проверки"
                : "Конфигурация готова · \(configuration.applications.filter(\.enabled).count) программ"
        } catch {
            // Keep the last known-good sing-box.json in place. The privileged
            // supervisor therefore never observes a partially edited config.
            validationMessage = "Не применено: \(error.localizedDescription)"
        }
    }

    private func writeGeneratedConfiguration(_ data: Data) throws {
        let directory = try applicationSupportDirectory()
        let url = directory.appendingPathComponent("sing-box.json")
        try writeIfChanged(data, to: url)
        generatedConfigPath = url.path
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }

    private var isPatchedSingBox: Bool {
        LocalSingBoxPatch.isActive && singBoxBinaryPath() == LocalSingBoxPatch.currentPath
    }

    private func validateWithSingBox(_ data: Data, policy: Data? = nil) throws {
        guard let binary = singBoxBinaryPath() else {
            throw RoutingConfigurationError.invalidMainConfiguration("sing-box не найден; установите brew install sing-box")
        }
        let directory = try applicationSupportDirectory()
        let candidate = directory.appendingPathComponent("sing-box.candidate.json")
        try data.write(to: candidate, options: .atomic)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let policyCandidate = directory.appendingPathComponent("sing-box-policy.candidate.json")
        if let policy {
            try policy.write(to: policyCandidate, options: .atomic)
        }
        defer { if policy != nil { try? FileManager.default.removeItem(at: policyCandidate) } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["check", "-c", candidate.path]
            + (policy == nil ? [] : ["--ipinformer-policy", policyCandidate.path])
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw RoutingConfigurationError.invalidMainConfiguration(output.isEmpty ? "sing-box отклонил файл" : output)
        }
    }

    private func applicationSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("IPInformer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func singBoxBinaryPath() -> String? {
        ["/Library/Application Support/IPInformer/engines/current", "/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box", "/usr/bin/sing-box"]
            .first(where: FileManager.default.fileExists(atPath:))
    }

}
