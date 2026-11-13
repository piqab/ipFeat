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
    @ObservedObject var monitor: IPMonitor
    @StateObject private var engine = EngineManager()
    @State private var draft = ""
    @State private var draftBaseline = ""
    @State private var editorExpanded = false
    @State private var manualCheckMessage: String?
    @State private var diffCandidate = ""
    @State private var diffIsHistory = false
    @State private var showDiff = false
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                serviceSection
                Divider()
                engineSection
                Divider()
                clientConnectionsSection
                Divider()
                editorSection
                Divider()
                historySection
                Divider()
                archiveSection
            }
            .padding(20)
        }
        .onAppear {
            editorExpanded = false
            if draft.isEmpty {
                draft = store.configuration.mainConfigurationJSON
                draftBaseline = draft
            }
            engine.refreshLocalState()
            Task { await engine.refreshReleases() }
        }
        .onChange(of: store.configuration.mainConfigurationJSON) { updated in
            if draft == draftBaseline { draft = updated }
            draftBaseline = updated
            manualCheckMessage = nil
        }
        .onChange(of: store.configuration) { _ in manualCheckMessage = nil }
        .onChange(of: store.validationMessage) { _ in manualCheckMessage = nil }
        .task {
            while !Task.isCancelled {
                engine.refreshLocalState()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .sheet(isPresented: $showDiff) {
            ConfigurationDiffView(
                store: store,
                old: store.configuration.mainConfigurationJSON, new: diffCandidate,
                title: "Изменения основной конфигурации",
                actionTitle: diffIsHistory ? "Восстановить версию" : "Проверить и сохранить"
            ) {
                let saved = store.applyMainConfigurationJSON(diffCandidate)
                if saved {
                    draft = store.configuration.mainConfigurationJSON
                    showDiff = false
                }
                return saved
            }
        }
        .sheet(item: $archiveMode) { mode in archiveSheet(mode) }
        .sheet(isPresented: $showNewServerWizard) { NewServerWizardView(store: store) }
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
            ClientQRSView(connection: connection, mainJSON: store.configuration.mainConfigurationJSON)
        }
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Сетевой движок").font(.headline)
            Toggle("Sing-box всегда активен", isOn: Binding(
                get: { store.configuration.singBoxAlwaysOn },
                set: { store.setAlwaysOn($0) }
            ))
            Text(store.validationMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Версия sing-box").font(.headline)
                Spacer()
                Button("Обновить список") { Task { await engine.refreshReleases() } }
                Button("Вернуть предыдущую") { Task { await engine.rollback() } }
                    .disabled(!engine.canRollback || engine.isInstalling)
            }
            Text(engine.isPatched ? "Работает: sing-box 1.14.4 · патч IP Informer 1.14.4-1" :
                    "Работает: \(engine.activeVersion ?? "системная версия \(engine.installedVersion ?? "не найдена")")")
                .font(.caption)
            HStack {
                Text(engine.isPatched ? "Патч IP Informer 1.14.4-1 активен · правила программ обновляются без обрыва соединений" :
                        "Патч IP Informer 1.14.4-1 добавляет обновление правил и маршруты дочерних команд")
                    .font(.caption)
                Spacer()
                if engine.isPatched {
                    Button("Вернуть официальный") { Task { await engine.removePatch() } }
                        .disabled(engine.isInstalling)
                } else {
                    Button("Установить патч") { Task { await engine.installPatch() } }
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
                    Task { await engine.installSelected() }
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
            ForEach(store.configuration.clientConnections) { connection in
                HStack {
                    VStack(alignment: .leading) {
                        Text(connection.name).fontWeight(.medium)
                        Text("\(connection.protocolName) · \(connection.serverIPv4) · \(connection.outboundTag)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
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
                                mainJSON: store.configuration.mainConfigurationJSON
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
                    Button("Удалить…", role: .destructive) { connectionToRemove = connection }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var editorSection: some View {
        DisclosureGroup(isExpanded: $editorExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Здесь находятся DNS, outbounds и общие правила. Перед сохранением показываются изменения; успешная версия попадает в историю.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 230)
                    .border(Color.secondary.opacity(0.25))
                HStack {
                    Text("Outbounds: \(store.outboundTags.joined(separator: ", "))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Проверить через sing-box") {
                        store.validateWithInstalledSingBox()
                        manualCheckMessage = store.runtimeMessage
                    }
                    .help("Проверяет сохранённую итоговую конфигурацию, включая правила программ")
                }
                HStack {
                    Spacer()
                    Button("Вернуть сохранённую") {
                        draft = store.configuration.mainConfigurationJSON
                        draftBaseline = draft
                    }
                    Button("Загрузить JSON…") { chooseJSON() }
                    Button("Сравнить и сохранить") {
                        diffCandidate = draft
                        diffIsHistory = false
                        showDiff = true
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == store.configuration.mainConfigurationJSON)
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Основная конфигурация sing-box").font(.headline)
                Label(editorStatus,
                      systemImage: editorStatusPassed ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(editorStatusPassed ? Color.secondary : Color.red)
            }
        }
    }

    private var editorStatus: String { manualCheckMessage ?? store.validationMessage }

    private var editorStatusPassed: Bool {
        if let manualCheckMessage { return manualCheckMessage == "sing-box: конфигурация корректна" }
        return store.validationMessage.hasPrefix("Конфигурация готова")
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("История конфигурации").font(.headline)
            Text("Хранятся 30 последних успешно сохранённых версий на этом Mac. Восстановление сначала откроет сравнение.")
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
                        diffIsHistory = true
                        showDiff = true
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
            Text("Архив включает маршруты, профили, группы, программы, источники IP и настройки виджетов. Приложения и системная служба в архив не входят.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Экспортировать с паролем…") { beginArchive(.export) }
                Button("Восстановить из архива…") { beginArchive(.restore) }
            }
        }
    }

    private func chooseJSON() {
        let panel = NSOpenPanel()
        panel.title = "Загрузить JSON sing-box для сравнения"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { draft = try String(contentsOf: url, encoding: .utf8) }
        catch { store.reportRuntimeError("Не удалось прочитать JSON: \(error.localizedDescription)") }
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
            Text(mode == .export ? "Зашифрованный экспорт" : "Восстановление из архива")
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
                Text("Профилей: \(pendingBackup.routing.profiles.count), групп: \(pendingBackup.routing.groups.count), программ: \(pendingBackup.routing.applications.count), источников IP: \(pendingBackup.sources.count)")
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
        panel.title = "Выберите зашифрованный архив IP Informer"
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
            archiveError = "Пароли не совпадают"
            return
        }
        let defaults = UserDefaults.standard
        let offsets = defaults.dictionaryRepresentation().compactMapValues { $0 as? String }
            .filter { $0.key.hasPrefix("widgetOffset.") }
        let backup = ConfigurationBackup(
            routing: store.configuration, sources: monitor.sources,
            checkInterval: monitor.interval,
            widgetsVisible: defaults.object(forKey: "widgetsVisible") == nil || defaults.bool(forKey: "widgetsVisible"),
            widgetOffsets: offsets,
            launchAtLogin: SMAppService.mainApp.status == .enabled,
            configurationHistory: store.configurationHistory,
            engineAutoInstall: engine.autoInstall,
            serverConfigurations: ServerSecretStore.all(for: store.configuration.clientConnections)
        )
        do {
            let encrypted = try ConfigurationArchive.encrypt(backup, password: password)
            let panel = NSSavePanel()
            panel.title = "Сохранить зашифрованный архив"
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
            missingApplications = try store.restoreConfiguration(
                pendingBackup.routing, history: pendingBackup.configurationHistory
            )
            monitor.restore(sources: pendingBackup.sources, interval: pendingBackup.checkInterval)
            if let engineAutoInstall = pendingBackup.engineAutoInstall {
                engine.autoInstall = engineAutoInstall
            }
            for (id, serverConfig) in pendingBackup.serverConfigurations ?? [:] {
                if let uuid = UUID(uuidString: id) {
                    try ServerSecretStore.save(serverConfig, id: uuid)
                }
            }
            let defaults = UserDefaults.standard
            defaults.set(pendingBackup.widgetsVisible, forKey: "widgetsVisible")
            for (key, value) in pendingBackup.widgetOffsets { defaults.set(value, forKey: key) }
            var loginIssue: String?
            do {
                if pendingBackup.launchAtLogin && SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                } else if !pendingBackup.launchAtLogin && SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch { loginIssue = error.localizedDescription }
            draft = store.configuration.mainConfigurationJSON
            archiveMode = nil
            password = ""
            let suffix = loginIssue.map { " Автозапуск не изменён: \($0)" } ?? ""
            store.reportRuntimeError("Архив восстановлен. Перезапустите IP Informer и установите системную службу.\(suffix)")
            NotificationCenter.default.post(name: .ipInformerConfigurationRestored, object: nil)
        } catch { archiveError = error.localizedDescription }
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
                Text(store.validationMessage).font(.caption).foregroundStyle(.red)
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
