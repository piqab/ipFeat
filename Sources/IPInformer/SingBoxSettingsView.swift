import AppKit
import ServiceManagement
import SwiftUI

private enum ArchiveMode: String, Identifiable {
    case export, restore
    var id: String { rawValue }
}

private struct ConnectionConfigDisplay: Identifiable {
    let id = UUID()
    let title: String
    let json: String
}

extension Notification.Name {
    static let ipInformerConfigurationRestored = Notification.Name("IPInformerConfigurationRestored")
}

struct SingBoxSettingsView: View {
    @ObservedObject var store: RoutingStore
    @StateObject private var engine = EngineManager()
    @StateObject private var service = NetworkServiceManager()
    @State private var diffCandidate = ""
    @State private var showHistoryDiff = false
    @State private var archiveMode: ArchiveMode?
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var archiveData: Data?
    @State private var archiveName = ""
    @State private var pendingBackup: ConfigurationBackup?
    @State private var missingApplications: [String] = []
    @State private var archiveError: String?
    @State private var showNewServerWizard = false
    @State private var displayedConnectionConfig: ConnectionConfigDisplay?
    @State private var connectionJSONError: String?
    @State private var connectionToRemove: ClientConnection?
    @State private var connectionToShare: ClientConnection?
    @State private var connectionToInspect: ClientConnection?
    @State private var pendingInstallations: [PendingServerInstallation] = []
    @State private var pendingToComplete: PendingServerInstallation?
    @State private var showServiceRemovalConfirmation = false
    @State private var showServiceLog = false
    @State private var showMigrationDiff = false
    @State private var migrationError: String?
    @State private var migrationReplacementTag = "direct"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                serviceSection
                Divider()
                engineSection
                Divider()
                clientConnectionsSection
                Divider()
                serverMigrationSection
                generatedConfigurationSection
                Divider()
                historySection
                Divider()
                archiveSection
            }
            .padding(20)
        }
        .onAppear {
            engine.refreshLocalState()
            pendingInstallations = PendingServerInstallationStore.all()
            Task { await engine.refreshReleases() }
        }
        .task {
            while !Task.isCancelled {
                engine.refreshLocalState()
                await service.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .sheet(isPresented: $showHistoryDiff) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configuration history diff").font(.headline)
                    ForEach(ConfigurationDiff.lines(old: diffCandidate, new: store.configuration.mainConfigurationJSON)) { line in
                        Text("\(line.marker) \(line.text)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.marker == "+" ? .green : line.marker == "-" ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding()
            }.frame(width: 780, height: 550)
        }
        .sheet(item: $archiveMode) { mode in archiveSheet(mode) }
        .sheet(isPresented: $showNewServerWizard) {
            NewServerWizardView(store: store)
                .onDisappear { pendingInstallations = PendingServerInstallationStore.all() }
        }
        .sheet(item: $pendingToComplete) { pending in
            PendingServerCompletionView(store: store, pending: pending)
                .onDisappear { pendingInstallations = PendingServerInstallationStore.all() }
        }
        .sheet(item: $displayedConnectionConfig) { item in
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline)
                ScrollView {
                    Text(item.json).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(width: 700, height: 550)
        }
        .sheet(item: $connectionToRemove) { connection in
            ClientRemovalView(store: store, connection: connection)
        }
        .sheet(item: $connectionToShare) { connection in
            ClientQRSView(connection: connection, mainJSON: store.configuration.mainConfigurationJSON,
                          domainRules: store.configuration.domainRules)
        }
        .sheet(item: $connectionToInspect) { connection in
            ServerInstallationView(store: store, connection: connection)
        }
        .sheet(isPresented: $showServiceLog) {
            ScrollView { Text(service.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding() }
                .frame(width: 780, height: 500)
        }
        .sheet(isPresented: $showMigrationDiff) {
            ConfigurationDiffView(store: store, old: store.configuration.mainConfigurationJSON,
                                  new: diffCandidate, title: "Replace legacy JSON with saved servers",
                                  actionTitle: "Use saved servers") {
                do {
                    try store.adoptSavedServerConfiguration(
                        replacementTag: store.serverConfigurationMigration.unresolvedRoutes.isEmpty
                            ? nil : migrationReplacementTag
                    )
                    showMigrationDiff = false
                    migrationError = nil
                    return true
                } catch {
                    migrationError = error.localizedDescription
                    return false
                }
            }
        }
        .confirmationDialog("Remove IP Informer network and updater services?", isPresented: $showServiceRemovalConfirmation) {
            Button("Remove services", role: .destructive) { Task { await service.remove() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The services and IP Informer PF rules will be removed. Saved servers, profiles and sing-box binaries remain.")
        }
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IP Informer network service").font(.headline)
                Spacer()
                Button("Refresh status") { Task { await service.refresh() } }.disabled(service.busy)
            }
            let state = service.snapshot
            Label(state.networkHealthy ? "Running · IP Informer controls sing-box" :
                    state.networkInstalled ? "Installed · not fully running" : "Not installed",
                  systemImage: state.networkHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(state.networkHealthy ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: AppLanguage.localized("launchd: %@"),
                            AppLanguage.localized(state.networkLoaded ? "loaded" : "not loaded")))
                Text(String(format: AppLanguage.localized("Supervisor PID: %@"),
                            state.supervisorPID.map { String($0) } ?? AppLanguage.localized("not found")))
                Text(String(format: AppLanguage.localized("Managed sing-box PID: %@"),
                            state.managedEnginePID.map { String($0) } ?? AppLanguage.localized("not found")))
                Text(String(format: AppLanguage.localized("utun100: %@"),
                            AppLanguage.localized(state.tunnelReady ? "ready" : "missing")))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Updater service: \(state.updaterInstalled ? (state.updaterLoaded ? "installed and loaded" : "installed, not loaded") : "not installed")")
                .font(.caption)
            if let path = state.configurationPath { Text("Installed service config: \(path)").font(.caption.monospaced()).textSelection(.enabled) }
            if !state.externalEngines.isEmpty {
                Text("Other sing-box processes (IP Informer does not control their routes):").font(.caption).foregroundStyle(.orange)
                ForEach(state.externalEngines, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
            }
            HStack {
                Button(state.networkInstalled ? "Reinstall services" : "Install services") { Task { await service.install() } }
                    .disabled(service.busy || !state.externalEngines.isEmpty)
                Button("Restart network service") { Task { await service.restart() } }
                    .disabled(service.busy || !state.networkLoaded)
                Button("Remove services", role: .destructive) { showServiceRemovalConfirmation = true }
                    .disabled(service.busy || (!state.networkInstalled && !state.updaterInstalled))
                Button("Network log") { Task { await service.loadLog(); showServiceLog = true } }
            }
            if service.busy { ProgressView("Updating service…") }
            if !service.message.isEmpty { Text(service.message).font(.caption).textSelection(.enabled) }
            Text(LocalizedStringKey(store.validationMessage)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Версия sing-box").font(.headline)
                Spacer()
                Button("Обновить список") { Task { await engine.refreshReleases() } }
                Button("Вернуть предыдущую") { Task { await engine.rollback(); await service.refresh() } }
                    .disabled(!engine.canRollback || engine.isInstalling)
            }
            Text(engine.isPatched ? "Работает: sing-box 1.14.4 · патч IP Informer 1.14.4-\(engine.activePatchRevision ?? 0)" :
                    "Работает: \(engine.activeVersion ?? "системная версия \(engine.installedVersion ?? "не найдена")")")
                .font(.caption)
            HStack {
                Text(engine.isPatched && engine.activePatchRevision != 5
                     ? "Patch 1.14.4-6 keeps route prompts open and applies saved process route changes immediately."
                     : engine.isPatched
                       ? "Patch 1.14.4-6 active · route prompts stay open until you choose."
                       : "Patch 1.14.4-6 adds live rules and persistent route prompts.")
                    .font(.caption)
                Spacer()
                if engine.isPatched {
                    if engine.activePatchRevision != 5 {
                        Button("Update patch") { Task { await engine.installPatch(); await service.refresh() } }
                            .disabled(engine.isInstalling)
                    }
                    Button("Вернуть официальный") { Task { await engine.removePatch(); await service.refresh() } }
                        .disabled(engine.isInstalling)
                } else {
                    Button("Установить патч") { Task { await engine.installPatch(); await service.refresh() } }
                        .disabled(engine.isInstalling)
                }
            }
            if engine.activeVersion == nil {
                Text("При первой установке выберите выпуск. macOS запросит пароль администратора для системной службы.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Показывать предварительные версии", isOn: $engine.showPrereleases)
                    .toggleStyle(.checkbox)
                Spacer()
                Picker("Установить версию", selection: $engine.selectedVersion) {
                    ForEach(engine.selectableReleases) { release in
                        Text(release.prerelease ? "\(release.version) · preview" : release.version)
                            .tag(release.version)
                    }
                }
                .frame(width: 285)
                Button(engine.activeVersion == nil ? "Установить" : "Переключить") {
                    Task { await engine.installSelected(); await service.refresh() }
                }
                .disabled(engine.isInstalling || engine.isPatched || !engine.selectableReleases.contains(where: { $0.version == engine.selectedVersion }))
                Button("Проверить") { Task { await engine.checkSelected() } }
                    .disabled(engine.isInstalling || engine.selectedRelease == nil)
            }
            if let selected = engine.selectedRelease {
                DisclosureGroup("Изменения выпуска \(selected.version)") {
                    Text(selected.body?.isEmpty == false ? selected.body! : "Изменения не описаны")
                        .font(.caption).textSelection(.enabled)
                }
            }
            if !engine.preflightOutput.isEmpty {
                Text(engine.preflightOutput).font(.caption.monospaced()).textSelection(.enabled)
            }
            Toggle("Автоматически устанавливать новые стабильные версии", isOn: $engine.autoInstall)
                .toggleStyle(.checkbox)
                .disabled(engine.isPatched)
            Text("При несовместимой конфигурации текущая версия продолжит работать. Проверка выполняется в течение 5 минут после включения, затем раз в сутки.")
                .font(.caption).foregroundStyle(.secondary)
            if engine.isInstalling { ProgressView("Проверка и установка…") }
            if !engine.message.isEmpty { Text(engine.message).font(.caption).foregroundStyle(.secondary) }
            if let error = engine.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            if !engine.history.isEmpty {
                Text("История версий и изменений").font(.subheadline.weight(.semibold))
                ForEach(engine.history) { record in
                    DisclosureGroup("\(record.version) · \(record.date.formatted(date: .abbreviated, time: .shortened))") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Предыдущая версия: \(record.previousVersion ?? "не было")")
                            Text("SHA-256 архива: \(record.checksum)").textSelection(.enabled)
                            Text("Изменения sing-box").fontWeight(.semibold)
                            ForEach(Array(record.releaseChanges.enumerated()), id: \.offset) { _, change in
                                Text(change).textSelection(.enabled)
                            }
                            Text("Изменения конфигурации").fontWeight(.semibold)
                            if record.configurationChanges.isEmpty { Text("Без изменений") }
                            ForEach(record.configurationChanges, id: \.self) { change in
                                Text(change).textSelection(.enabled)
                            }
                            if !record.validationOutput.isEmpty {
                                Text("Результат проверки: \(record.validationOutput)")
                            }
                        }
                        .font(.caption.monospaced())
                        .padding(8)
                    }
                }
            }
        }
    }

    private var clientConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Клиентские подключения").font(.headline)
                Spacer()
                Button("Новый сервер…") { showNewServerWizard = true }
            }
            if store.configuration.clientConnections.isEmpty {
                Text("Создайте новый VPS: клиентский конфиг добавится сюда и станет доступен для программ, групп и общего маршрута.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let connectionJSONError {
                Text(connectionJSONError).font(.caption).foregroundStyle(.red)
            }
            if !pendingInstallations.isEmpty {
                Text("Pending manual installations").font(.subheadline.weight(.semibold))
                ForEach(pendingInstallations) { pending in
                    HStack {
                        Text("\(pending.name) · \(pending.serverIPv4) · sing-box \(pending.version)")
                            .font(.caption)
                        Spacer()
                        Button("Complete installation…") { pendingToComplete = pending }
                        Button("Discard", role: .destructive) {
                            PendingServerInstallationStore.remove(pending.id)
                            pendingInstallations = PendingServerInstallationStore.all()
                        }
                    }
                }
            }
            ForEach(store.configuration.clientConnections) { connection in
                HStack {
                    VStack(alignment: .leading) {
                        Text(connection.name).fontWeight(.medium)
                        Text("\(connection.protocolName) · \(connection.serverIPv4) · \(connection.outboundTag)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(AppLanguage.localized(connection.installationVerified == true ? "Verified on VPS" :
                             (connection.installationVerified == false ? "Installation not verified" : "Installation not checked")))
                            .font(.caption).foregroundStyle(connection.installationVerified == true ? Color.green : Color.secondary)
                    }
                    Spacer()
                    if store.configuration.defaultRoute == .outbound(connection.outboundTag) {
                        Text("Общий маршрут").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Сделать общим") { store.activateClientConnection(connection.id) }
                    }
                    Button("Поделиться QRS") { connectionToShare = connection }
                    Button("Клиентский JSON") {
                        do {
                            let json = try ClientQRS.androidConfiguration(
                                connection: connection,
                                mainJSON: store.configuration.mainConfigurationJSON,
                                domainRules: store.configuration.domainRules
                            )
                            displayedConnectionConfig = ConnectionConfigDisplay(
                                title: "Клиентский JSON · \(connection.name)", json: json
                            )
                            connectionJSONError = nil
                        } catch {
                            connectionJSONError = error.localizedDescription
                        }
                    }
                    Button("Серверный JSON") {
                        displayedConnectionConfig = ServerSecretStore.load(id: connection.id).map {
                            ConnectionConfigDisplay(title: "Серверный JSON · \(connection.name)", json: $0)
                        }
                        connectionJSONError = displayedConnectionConfig == nil
                            ? "Серверный конфиг не найден в Keychain" : nil
                    }
                    Button("Installation / Check…") { connectionToInspect = connection }
                    Button("Удалить…", role: .destructive) { connectionToRemove = connection }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var serverMigrationSection: some View {
        Group {
            if !store.configuration.usesManagedServerConfiguration {
                let report = store.serverConfigurationMigration
                VStack(alignment: .leading, spacing: 8) {
                    Text("Move from legacy JSON to saved servers").font(.headline)
                    Text("IP Informer has preserved the current configuration. Reassign unavailable routes before generating a new one from saved server connections.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !report.unmanagedTags.isEmpty {
                        Text("Channels that will be removed: \(report.unmanagedTags.joined(separator: ", "))")
                            .font(.caption.monospaced()).foregroundStyle(.orange)
                    }
                    ForEach(report.unresolvedRoutes, id: \.self) { reference in
                        Text(reference).font(.caption.monospaced()).foregroundStyle(.orange)
                    }
                    if !report.unresolvedRoutes.isEmpty {
                        Picker("Replace unavailable routes with", selection: $migrationReplacementTag) {
                            Text("direct").tag("direct")
                            ForEach(store.configuration.clientConnections.filter { $0.outboundJSON != nil }) { connection in
                                Text(connection.name).tag(connection.outboundTag)
                            }
                        }
                        .frame(maxWidth: 360)
                        Text("The listed profiles, child commands, saved processes and legacy WebKit choice will use this route when their old channel is removed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.configuration.clientConnections.filter { $0.outboundJSON == nil }) { connection in
                        HStack {
                            Text("Missing client outbound: \(connection.name)").font(.caption)
                            Button("Load client outbound JSON…") { chooseClientOutbound(for: connection) }
                        }
                    }
                    Button("Review generated configuration") {
                        do {
                            diffCandidate = try store.previewManagedServerConfiguration()
                            migrationError = nil
                            showMigrationDiff = true
                        } catch { migrationError = error.localizedDescription }
                    }
                    .disabled(!report.missingConnections.isEmpty)
                    if let migrationError { Text(migrationError).font(.caption).foregroundStyle(.red) }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var generatedConfigurationSection: some View {
        HStack {
            Text("Generated sing-box configuration").font(.subheadline.weight(.semibold))
            Spacer()
            Button("View JSON") {
                let json = (try? String(contentsOfFile: store.generatedConfigPath, encoding: .utf8))
                    ?? store.configuration.mainConfigurationJSON
                displayedConnectionConfig = ConnectionConfigDisplay(title: "Generated sing-box JSON", json: json)
            }
            Button("Check with sing-box") { store.validateWithInstalledSingBox() }
        }
    }

    private func chooseClientOutbound(for connection: ClientConnection) {
        let panel = NSOpenPanel()
        panel.title = "Select client outbound JSON for \(connection.name)"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            try store.restoreClientOutbound(connection.id, json: json)
            migrationError = nil
        } catch { migrationError = error.localizedDescription }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("История конфигурации").font(.headline)
            Text("Saved configuration snapshots can be compared with the current generated JSON. Restore a complete encrypted backup to recover old server connections.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.configurationHistory) { revision in
                HStack {
                    Text(revision.date, format: .dateTime.year().month().day().hour().minute().second())
                    if revision.json == store.configuration.mainConfigurationJSON {
                        Text("текущая").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Посмотреть") {
                        diffCandidate = revision.json
                        showHistoryDiff = true
                    }
                    .disabled(revision.json == store.configuration.mainConfigurationJSON)
                }
                .font(.caption)
                .padding(7)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Перенос на другой Mac").font(.headline)
            Text("The encrypted archive includes routing, pending VPS installations, client and server JSON, AI settings and readable API keys. Missing server secrets stop export. App bundles, sing-box binaries and the system service are not included.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Экспортировать с паролем…") { beginArchive(.export) }
                Button("Восстановить из архива…") { beginArchive(.restore) }
            }
        }
    }

    private func beginArchive(_ mode: ArchiveMode) {
        password = ""
        passwordConfirmation = ""
        archiveData = nil
        archiveName = ""
        pendingBackup = nil
        missingApplications = []
        archiveError = nil
        archiveMode = mode
    }

    private func archiveSheet(_ mode: ArchiveMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(mode == .export ? "Зашифрованный экспорт" : "Восстановление из архива"))
                .font(.title3.weight(.semibold))
            if mode == .restore {
                Button(archiveName.isEmpty ? "Выбрать архив…" : archiveName) { chooseArchive() }
            }
            SecureField("Пароль", text: $password)
            if mode == .export {
                SecureField("Повторите пароль", text: $passwordConfirmation)
                Text("Архив шифруется с проверкой целостности. Сохраните пароль: без него восстановление невозможно.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let archiveError {
                Text(archiveError).foregroundStyle(.red).font(.caption)
            }
            if mode == .restore, let pendingBackup {
                Text(String(format: AppLanguage.localized("Profiles: %ld · groups: %ld · apps: %ld · commands: %ld · saved routes: %ld · client connections: %ld"),
                            pendingBackup.routing.profiles.count, pendingBackup.routing.groups.count,
                            pendingBackup.routing.applications.count, pendingBackup.routing.commands.count,
                            pendingBackup.routing.savedProcessRoutes.count,
                            pendingBackup.routing.clientConnections.count))
                    .font(.caption)
                Text(String(format: AppLanguage.localized("Pending VPS installations: %ld"),
                            pendingBackup.pendingServerInstallations?.count ?? 0))
                    .font(.caption)
                if !missingApplications.isEmpty {
                    Text("Не найдены и будут выключены: \(missingApplications.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Текущие настройки будут заменены. После восстановления перезапустите IP Informer и установите системную службу на этом Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { archiveMode = nil }
                if mode == .export {
                    Button("Сохранить файл…") { exportArchive() }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.count < 8 || password != passwordConfirmation)
                } else if pendingBackup != nil {
                    Button("Восстановить") { restoreArchive() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Проверить архив") { decryptArchive() }
                        .buttonStyle(.borderedProminent)
                        .disabled(archiveData == nil || password.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 510)
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("Выберите зашифрованный архив IP Informer")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            archiveData = try Data(contentsOf: url)
            archiveName = url.lastPathComponent
            pendingBackup = nil
            archiveError = nil
        } catch { archiveError = error.localizedDescription }
    }

    private func decryptArchive() {
        guard let archiveData else { return }
        do {
            let backup = try ConfigurationArchive.decrypt(archiveData, password: password)
            let prepared = RoutingStore.prepareRestoredConfiguration(backup.routing)
            _ = try SingBoxConfigurationGenerator.data(for: prepared.configuration)
            pendingBackup = backup
            missingApplications = prepared.missingApplications
            archiveError = nil
        } catch { archiveError = error.localizedDescription }
    }

    private func exportArchive() {
        guard password == passwordConfirmation else {
            archiveError = AppLanguage.localized("Пароли не совпадают")
            return
        }
        do {
            let defaults = UserDefaults.standard
            let backup = ConfigurationBackup(
                routing: store.configuration,
                launchAtLogin: SMAppService.mainApp.status == .enabled,
                configurationHistory: store.configurationHistory,
                engineAutoInstall: engine.autoInstall,
                serverConfigurations: try ServerSecretStore.allRequired(for: store.configuration.clientConnections),
                processAISettings: try ProcessAISettings.shared.snapshot(),
                preferredAppLanguage: defaults.string(forKey: AppLanguage.preferenceKey),
                pendingServerInstallations: try PendingServerInstallationStore.allChecked()
            )
            let encrypted = try ConfigurationArchive.encrypt(backup, password: password)
            let panel = NSSavePanel()
            panel.title = AppLanguage.localized("Сохранить зашифрованный архив")
            panel.nameFieldStringValue = "IPInformer.ipibackup"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try encrypted.write(to: url, options: .atomic)
            archiveMode = nil
            password = ""
        } catch { archiveError = error.localizedDescription }
    }

    private func restoreArchive() {
        guard let pendingBackup else { return }
        do {
            missingApplications = try applyArchiveTransaction(pendingBackup)
            if let engineAutoInstall = pendingBackup.engineAutoInstall {
                engine.autoInstall = engineAutoInstall
            }
            if let language = pendingBackup.preferredAppLanguage {
                AppLanguage.set(language)
            }
            var loginIssue: String?
            do {
                if pendingBackup.launchAtLogin && SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                } else if !pendingBackup.launchAtLogin && SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch { loginIssue = error.localizedDescription }
            archiveMode = nil
            password = ""
            pendingInstallations = PendingServerInstallationStore.all()
            let suffix = loginIssue.map { " Автозапуск не изменён: \($0)" } ?? ""
            store.reportRuntimeError("Архив восстановлен. Перезапустите IP Informer и установите системную службу.\(suffix)")
            NotificationCenter.default.post(name: .ipInformerConfigurationRestored, object: nil)
        } catch { archiveError = error.localizedDescription }
    }

    private func applyArchiveTransaction(_ backup: ConfigurationBackup) throws -> [String] {
        try ConfigurationArchive.validateContents(backup)
        let priorAI = try backup.processAISettings.map { _ in try ProcessAISettings.shared.snapshot() }
        let priorPending = try backup.version >= 2 ? PendingServerInstallationStore.allChecked() : nil
        var incomingSecrets: [UUID: String] = [:]
        for (rawID, json) in backup.serverConfigurations ?? [:] {
            guard let id = UUID(uuidString: rawID) else {
                throw BackupError.incompleteArchive(String(format: AppLanguage.localized("Invalid server ID in archive: %@"), rawID))
            }
            incomingSecrets[id] = json
        }
        let restoredIDs = Set(backup.routing.clientConnections.map(\.id))
        let oldIDs = Set(store.configuration.clientConnections.map(\.id))
        let obsoleteIDs = oldIDs.subtracting(restoredIDs)
        let touchedIDs = Set(incomingSecrets.keys).union(obsoleteIDs)
        var priorSecrets: [UUID: String] = [:]
        for id in touchedIDs {
            if let json = try ServerSecretStore.loadChecked(id: id) { priorSecrets[id] = json }
        }

        do {
            for (id, json) in incomingSecrets { try ServerSecretStore.save(json, id: id) }
            for id in obsoleteIDs { try ServerSecretStore.deleteChecked(id: id) }
            if let ai = backup.processAISettings { try ProcessAISettings.shared.restore(ai) }
            if backup.version >= 2 {
                try PendingServerInstallationStore.replaceAll(with: backup.pendingServerInstallations ?? [])
            }
            return try store.restoreConfiguration(backup.routing, history: backup.configurationHistory)
        } catch {
            let originalError = error
            var rollbackErrors: [String] = []
            if let priorPending {
                do { try PendingServerInstallationStore.replaceAll(with: priorPending) }
                catch { rollbackErrors.append("pending VPS installations: \(error.localizedDescription)") }
            }
            if let priorAI {
                let priorIDs = Set(priorAI.profiles.map(\.id))
                for profile in backup.processAISettings?.profiles ?? [] where !priorIDs.contains(profile.id) {
                    do { try ProcessAIKeychain.deleteChecked(id: profile.id) }
                    catch { rollbackErrors.append("AI key \(profile.id.uuidString): \(error.localizedDescription)") }
                }
                do { try ProcessAISettings.shared.restore(priorAI) }
                catch { rollbackErrors.append("AI settings: \(error.localizedDescription)") }
            }
            for id in touchedIDs {
                do {
                    if let previous = priorSecrets[id] {
                        try ServerSecretStore.save(previous, id: id)
                    } else {
                        try ServerSecretStore.deleteChecked(id: id)
                    }
                } catch { rollbackErrors.append("server \(id.uuidString): \(error.localizedDescription)") }
            }
            let detail = rollbackErrors.isEmpty ? "" : String(format: AppLanguage.localized("Rollback errors: %@"),
                                                                    rollbackErrors.joined(separator: "; "))
            throw BackupError.incompleteArchive(String(format: AppLanguage.localized("Restore failed: %@. %@"),
                                                       originalError.localizedDescription, detail))
        }
    }
}

private struct ConfigurationDiffView: View {
    @ObservedObject var store: RoutingStore
    let old: String
    let new: String
    let title: String
    let actionTitle: String
    let apply: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text("Зелёные строки добавляются, красные удаляются. Секреты из JSON видны в сравнении.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ConfigurationDiff.lines(old: old, new: new)) { line in
                        Text(String(line.marker) + " " + line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.marker == "+" ? .green : line.marker == "-" ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                    }
                }
                .textSelection(.enabled)
            }
            .border(Color.secondary.opacity(0.25))
            if store.validationMessage.hasPrefix("Не применено") {
                Text(LocalizedStringKey(store.validationMessage)).font(.caption).foregroundStyle(.red)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button(actionTitle) {
                    if !apply() { errorMessage = store.runtimeMessage }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 760, height: 520)
    }
}
