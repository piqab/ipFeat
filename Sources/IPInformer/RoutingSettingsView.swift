import AppKit
import SwiftUI

enum RoutingSettingsSection { case programs, profiles }

struct RoutingSettingsView: View {
    @ObservedObject var store: RoutingStore
    let section: RoutingSettingsSection
    @State private var addError: String?
    @State private var commandError: String?
    @State private var collapsedGroupIDs: Set<UUID> = []
    @State private var editingGroupID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch section {
                case .programs:
                    defaultRouteSection
                    Divider()
                    applicationsSection
                    Divider()
                    commandsSection
                    Divider()
                    redirectsSection
                case .profiles:
                    profilesSection
                }
            }
            .padding(20)
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Профили").font(.headline)
                Spacer()
                Button("Добавить профиль", systemImage: "plus") { store.addProfile() }
            }

            if store.configuration.profiles.isEmpty {
                emptyHint("Создайте профиль и выберите outbound из основной конфигурации.")
            }

            ForEach(store.configuration.profiles) { profile in
                profileEditor(profile)
            }
        }
    }

    private var defaultRouteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Маршрут остальных программ").font(.headline)
            Picker("Маршрут по умолчанию", selection: Binding(
                get: { store.selectedDefaultRoute },
                set: { store.setDefaultRoute($0) }
            )) {
                if case .outbound(let selectedTag) = store.selectedDefaultRoute,
                   !store.outboundTags.contains(selectedTag) {
                    Text("\(selectedTag) · не найден").tag(DefaultRoute.outbound(selectedTag))
                }
                ForEach(store.outboundTags, id: \.self) { tag in
                    Text(tag).tag(DefaultRoute.outbound(tag))
                }
                Text("Только этот Mac").tag(DefaultRoute.localOnly)
                Text("Без сети").tag(DefaultRoute.block)
            }
            .frame(maxWidth: 420)
            Text("Действует для программ без личного или группового профиля, включая выключенные. Общие правила импортированного JSON для них не применяются. В вариантах «Только этот Mac» и «Без сети» localhost остаётся доступен.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Встроенные веб-приложения (WebKit) через proxy", isOn: Binding(
                get: { store.configuration.webKitProxyEnabled },
                set: { store.setWebKitProxyEnabled($0) }
            ))
            .disabled(!store.outboundTags.contains("proxy") && !store.configuration.webKitProxyEnabled)
            Text("Для Telegram Web Apps и встроенных веб-страниц других программ. Сетевой процесс WebKit общий, поэтому это правило действует для всех таких страниц. Остальные программы сохраняют выбранный выше маршрут. Для изменения правила sing-box обновит конфигурацию и активные соединения могут прерваться.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func profileEditor(_ profile: RoutingProfile) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if profile.isBuiltIn {
                    Text(builtInDescription(profile.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                  HStack {
                    Text("Маршрут sing-box")
                    Picker("", selection: profileBinding(profile, \.outboundTag)) {
                        if !store.outboundTags.contains(profile.outboundTag), !profile.outboundTag.isEmpty {
                            Text("\(profile.outboundTag) · не найден").tag(profile.outboundTag)
                        }
                        Text("Не выбран").tag("")
                        ForEach(store.outboundTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 330)
                    Spacer()
                  }
                }
                Text("Параметры сервера, физического интерфейса и цепочки прокси задаются внутри выбранного outbound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                TextField("Название профиля", text: profileBinding(profile, \.name))
                    .textFieldStyle(.plain)
                    .disabled(profile.isBuiltIn)
                Spacer()
                Text(profile.isBuiltIn ? "встроенный" : (profile.outboundTag.isEmpty ? "outbound не выбран" : profile.outboundTag))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !profile.isBuiltIn {
                    Button(role: .destructive) { store.removeProfile(profile) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var redirectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Перенаправления во внутреннюю сеть").font(.headline)
                Spacer()
                Button("Добавить правило", systemImage: "plus") { store.addRedirect() }
                    .disabled(store.configuration.applications.isEmpty)
            }
            if store.configuration.redirects.isEmpty {
                emptyHint("Например: Blisk · example.com:443 → 192.168.101.200:32445")
            }
            ForEach(store.configuration.redirects) { redirect in
                HStack(spacing: 7) {
                    Toggle("", isOn: redirectBinding(redirect, \.enabled)).labelsHidden()
                    Picker("", selection: redirectBinding(redirect, \.applicationID)) {
                        Text("Программа").tag(UUID?.none)
                        ForEach(store.configuration.applications) { app in
                            Text(app.name).tag(Optional(app.id))
                        }
                    }.frame(width: 145)
                    TextField("example.com", text: redirectBinding(redirect, \.sourceDomain)).frame(minWidth: 130)
                    Text(":")
                    TextField("443", value: redirectBinding(redirect, \.sourcePort), format: .number).frame(width: 52)
                    Image(systemName: "arrow.right")
                    TextField("127.0.0.1", text: redirectBinding(redirect, \.targetAddress)).frame(width: 125)
                    Text(":")
                    TextField("443", value: redirectBinding(redirect, \.targetPort), format: .number).frame(width: 60)
                    Button(role: .destructive) { store.removeRedirect(redirect) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
            Text("TCP перенаправляется напрямую; UDP/QUIC для совпавшего домена и порта блокируется. Сертификат внутреннего сервиса должен соответствовать исходному домену.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func builtInDescription(_ kind: RoutingProfileKind) -> String {
        switch kind {
        case .block: return "Полностью блокирует сетевой трафик выбранной программы."
        case .localOnly: return "Разрешает только localhost (127.0.0.0/8 и ::1), остальное блокирует."
        case .localNetwork: return "Разрешает localhost, частные подсети и Bonjour/mDNS; публичные адреса блокирует."
        case .outbound: return ""
        }
    }

    private var applicationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Программы и группы").font(.headline)
                Spacer()
                Button("Добавить группу", systemImage: "folder.badge.plus") { store.addGroup() }
            }
            Text("Добавление, удаление и перенос программ меняют правила sing-box. При их применении текущие соединения могут прерваться; выбор нескольких программ за один раз вызывает одно обновление.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !store.applicationActionMessage.isEmpty {
                Text(store.applicationActionMessage).font(.caption).foregroundStyle(.secondary)
            }

            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            ForEach(store.configuration.groups) { group in
                groupCard(group)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Без группы", systemImage: "square.stack")
                        .font(.headline)
                    Text("\(ungroupedApplications.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Добавить программы", systemImage: "plus") { chooseApplications(toGroup: nil) }
                }
                ForEach(ungroupedApplications) { application in
                    applicationEditor(application)
                }
                if ungroupedApplications.isEmpty {
                    emptyHint("Здесь можно назначить личный профиль или использовать общий маршрут.")
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var ungroupedApplications: [RoutedApplication] {
        store.configuration.applications.filter { application in
            guard let groupID = application.groupID else { return true }
            return !store.configuration.groups.contains { $0.id == groupID }
        }
    }

    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Команды терминала").font(.headline)
                Spacer()
                Button("Добавить SSH, curl и nc") {
                    let urls = ["/usr/bin/ssh", "/usr/bin/curl", "/usr/bin/nc"].map(URL.init(fileURLWithPath:))
                    let errors = store.addCommands(at: urls)
                    commandError = errors.isEmpty ? nil : errors.joined(separator: "\n")
                }
                Button("Выбрать файлы…", systemImage: "plus") { chooseCommands() }
            }
            Text("Правило привязано к исполняемому файлу: оно действует для команды из iTerm, Terminal и других программ. Выберите внешний маршрут; локальные IPv4 можно направить напрямую независимо от него. Для произвольных дочерних процессов iTerm правило автоматически не наследуется.")
                .font(.caption).foregroundStyle(.secondary)
            if let commandError {
                Text(commandError).font(.caption).foregroundStyle(.red)
            }
            ForEach(store.configuration.commands) { command in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Toggle("", isOn: commandBinding(command, \.enabled)).labelsHidden()
                        Image(systemName: "terminal").frame(width: 28)
                        Text(command.name).fontWeight(.medium)
                        Spacer()
                        Button(role: .destructive) { store.removeCommand(command) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(command.executablePath)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !FileManager.default.isExecutableFile(atPath: command.executablePath) {
                        Button("Найти команду…") { chooseCommandReplacement(for: command) }
                            .font(.caption)
                    }
                    Picker("Маршрут команды", selection: commandBinding(command, \.profileID)) {
                        Text("Общий маршрут").tag(UUID?.none)
                        ForEach(store.configuration.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .frame(maxWidth: 420)
                    Toggle("Локальные IPv4 напрямую", isOn: commandBinding(command, \.allowLocalNetwork))
                        .controlSize(.small)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if store.configuration.commands.isEmpty {
                emptyHint("Добавьте исполняемый файл команды, например /usr/bin/ssh.")
            }
        }
    }

    private func chooseCommands() {
        let panel = NSOpenPanel()
        panel.title = "Выберите исполняемые файлы команд"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return }
        let errors = store.addCommands(at: panel.urls)
        commandError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func chooseCommandReplacement(for command: RoutedCommand) {
        let panel = NSOpenPanel()
        panel.title = "Найдите команду \(command.name)"
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commandError = store.relinkCommand(command, to: url)
    }

    private func groupCard(_ group: RoutingGroup) -> some View {
        let members = store.configuration.applications.filter { $0.groupID == group.id }
        let isCollapsed = collapsedGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if isCollapsed { collapsedGroupIDs.remove(group.id) }
                    else { collapsedGroupIDs.insert(group.id) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Развернуть группу" : "Свернуть группу")
                Circle().fill(group.color.displayColor).frame(width: 12, height: 12)
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(group.color.displayColor)
                    .lineLimit(1)
                Text("\(members.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(groupRouteTitle(group))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(group.color.displayColor.opacity(0.13), in: Capsule())
                Spacer(minLength: 4)
                Button { chooseApplications(toGroup: group.id) } label: {
                    Image(systemName: "plus")
                }
                .help("Добавить программы в группу")
                .accessibilityLabel("Добавить программы в группу")
                Button { editingGroupID = group.id } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                    .help("Изменить группу")
                    .accessibilityLabel("Изменить группу")
                    .popover(isPresented: Binding(
                        get: { editingGroupID == group.id },
                        set: { if !$0 { editingGroupID = nil } }
                    )) {
                        groupEditor(group)
                            .padding(16)
                            .frame(width: 350)
                    }
                Button(role: .destructive) { store.removeGroup(group) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить группу; программы останутся в разделе «Без группы»")
            }
            if !isCollapsed {
                if members.isEmpty { emptyHint("Добавьте программы в группу.") }
                ForEach(members) { application in
                    applicationEditor(application)
                }
            }
        }
        .padding(12)
        .background(group.color.displayColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(group.color.displayColor.opacity(0.3)))
    }

    private func groupEditor(_ group: RoutingGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Изменить группу").font(.headline)
            TextField("Название группы", text: groupBinding(group, \.name))
            Picker("Цвет", selection: groupBinding(group, \.color)) {
                ForEach(RoutingGroupColor.allCases, id: \.self) { color in
                    Text(color.title).tag(color)
                }
            }
            Picker("Маршрут", selection: groupBinding(group, \.profileID)) {
                Text("Общий маршрут").tag(UUID?.none)
                ForEach(store.configuration.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            Text("Маршрут группы действует для всех её программ. Сохранённый личный профиль включится после переноса программы в «Без группы».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func groupRouteTitle(_ group: RoutingGroup) -> String {
        guard let profileID = group.profileID else { return defaultRouteTitle }
        guard let profile = store.configuration.profiles.first(where: { $0.id == profileID }) else {
            return "Профиль не найден"
        }
        return profile.kind == .outbound ? "\(profile.name) · \(profile.outboundTag)" : profile.name
    }

    private var defaultRouteTitle: String {
        switch store.selectedDefaultRoute {
        case .outbound(let tag): return "Общий · \(tag)"
        case .localOnly: return "Общий · Только этот Mac"
        case .block: return "Общий · Без сети"
        }
    }

    private func applicationEditor(_ application: RoutedApplication) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle("", isOn: applicationBinding(application, \.enabled)).labelsHidden()
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(application.name).fontWeight(.medium)
                Spacer()
                Button("Запустить") { store.launch(application) }
                    .disabled(!application.enabled || application.bundleIdentifier == RoutingStore.selfBundleIdentifier)
                if application.bundleIdentifier != RoutingStore.selfBundleIdentifier {
                    Button(role: .destructive) { store.removeApplication(application) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(application.executablePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if application.bundleIdentifier == RoutingStore.selfBundleIdentifier,
               !store.configuration.selfProxySeeded {
                Text("Добавьте outbound proxy в конфигурацию sing-box: он будет назначен IP Informer автоматически.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !FileManager.default.fileExists(atPath: application.bundlePath) {
                Button("Найти программу…") { chooseReplacement(for: application) }
                    .font(.caption)
            }

            HStack {
                Picker("Группа", selection: applicationBinding(application, \.groupID)) {
                    Text("Без группы").tag(UUID?.none)
                    ForEach(store.configuration.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                if application.groupID == nil {
                    Picker("Личный профиль", selection: applicationBinding(application, \.profileID)) {
                        Text("Общий маршрут").tag(UUID?.none)
                        ForEach(store.configuration.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                }
                Toggle("Запускать после готовности сети", isOn: applicationBinding(application, \.launchAfterEngineReady))
            }
            .controlSize(.small)

            Toggle("Доступ к локальной сети напрямую", isOn: applicationBinding(application, \.allowLocalNetwork))
                .controlSize(.small)
                .help("Для этой программы локальные IPv4 идут через сеть Mac при любом выбранном маршруте. Публичные адреса следуют маршруту программы или группы.")

            HStack(spacing: 6) {
                Text(application.enabled ? "Внешний IP маршрута:" : "Внешний IP маршрута (программа выключена):")
                    .foregroundStyle(.secondary)
                let address = routeAddress(for: application)
                Text(address)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(address == "OFF" ? .red : .primary)
                Spacer()
                if let tag = store.effectiveOutboundTag(for: application) {
                    Button("Проверить") { store.checkRouteAddressesNow(for: [tag]) }
                        .disabled(store.isCheckingRoute(tag) || !store.outboundTags.contains(tag))
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func routeAddress(for application: RoutedApplication) -> String {
        guard let tag = store.effectiveOutboundTag(for: application) else { return "Нет внешнего маршрута" }
        guard store.outboundTags.contains(tag) else { return "Маршрут недоступен" }
        guard store.validationMessage.hasPrefix("Конфигурация готова") else { return "Конфигурация не применена" }
        if let address = store.routeAddresses[tag] { return address }
        return store.isCheckingRoute(tag) ? "Проверка…" : "Не проверен"
    }

    private func chooseApplications(toGroup groupID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "Выберите программы"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let errors = store.addApplications(at: panel.urls, toGroup: groupID)
        addError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func chooseReplacement(for application: RoutedApplication) {
        let panel = NSOpenPanel()
        panel.title = "Найдите \(application.name)"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addError = store.relinkApplication(application, to: url)
    }

    private func profileBinding<Value>(_ profile: RoutingProfile, _ keyPath: WritableKeyPath<RoutingProfile, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration.profiles.first(where: { $0.id == profile.id })?[keyPath: keyPath] ?? profile[keyPath: keyPath] },
            set: { value in
                var updated = store.configuration.profiles.first(where: { $0.id == profile.id }) ?? profile
                updated[keyPath: keyPath] = value
                store.updateProfile(updated)
            }
        )
    }

    private func groupBinding<Value>(_ group: RoutingGroup, _ keyPath: WritableKeyPath<RoutingGroup, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration.groups.first(where: { $0.id == group.id })?[keyPath: keyPath] ?? group[keyPath: keyPath] },
            set: { value in
                var updated = store.configuration.groups.first(where: { $0.id == group.id }) ?? group
                updated[keyPath: keyPath] = value
                store.updateGroup(updated)
            }
        )
    }

    private func applicationBinding<Value>(_ app: RoutedApplication, _ keyPath: WritableKeyPath<RoutedApplication, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration.applications.first(where: { $0.id == app.id })?[keyPath: keyPath] ?? app[keyPath: keyPath] },
            set: { value in
                var updated = store.configuration.applications.first(where: { $0.id == app.id }) ?? app
                updated[keyPath: keyPath] = value
                store.updateApplication(updated)
            }
        )
    }

    private func commandBinding<Value>(_ command: RoutedCommand, _ keyPath: WritableKeyPath<RoutedCommand, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration.commands.first(where: { $0.id == command.id })?[keyPath: keyPath] ?? command[keyPath: keyPath] },
            set: { value in
                var updated = store.configuration.commands.first(where: { $0.id == command.id }) ?? command
                updated[keyPath: keyPath] = value
                store.updateCommand(updated)
            }
        )
    }

    private func redirectBinding<Value>(_ redirect: ApplicationRedirect, _ keyPath: WritableKeyPath<ApplicationRedirect, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration.redirects.first(where: { $0.id == redirect.id })?[keyPath: keyPath] ?? redirect[keyPath: keyPath] },
            set: { value in
                var updated = store.configuration.redirects.first(where: { $0.id == redirect.id }) ?? redirect
                updated[keyPath: keyPath] = value
                store.updateRedirect(updated)
            }
        )
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

private extension RoutingGroupColor {
    var displayColor: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .red: return .red
        case .teal: return .teal
        }
    }
}
