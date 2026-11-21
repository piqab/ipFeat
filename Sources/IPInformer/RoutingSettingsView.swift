import AppKit
import SwiftUI

enum RoutingSettingsSection { case programs, profiles }

private enum GroupEntry: Identifiable {
    case application(RoutedApplication)
    case process(SavedProcessRoute)

    var id: UUID {
        switch self {
        case .application(let value): value.id
        case .process(let value): value.id
        }
    }

    var name: String {
        switch self {
        case .application(let value): value.name
        case .process(let value): URL(fileURLWithPath: value.executablePath).lastPathComponent
        }
    }
}

struct RoutingSettingsView: View {
    @ObservedObject var store: RoutingStore
    let section: RoutingSettingsSection
    @State private var addError: String?
    @State private var commandError: String?
    @State private var processRouteError: String?
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var isUngroupedExpanded = false
    @State private var isSavedProcessExpanded = false
    @State private var isCommandsExpanded = false
    @State private var isRedirectsExpanded = false
    @State private var isDomainsExpanded = false
    @State private var domainSearch = ""
    @State private var programSearch = ""
    @State private var editingDomainRule: DomainRouteRule?
    @State private var editingGroupID: UUID?
    @State private var selectedApplicationIDs: Set<UUID> = []
    @State private var selectedProcessRouteIDs: Set<UUID> = []
    @State private var selectedCommandIDs: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch section {
                case .programs:
                    TextField("Search apps, groups, commands and saved processes", text: $programSearch)
                        .textFieldStyle(.roundedBorder)
                    defaultRouteSection
                    Divider()
                    domainsSection
                    Divider()
                    applicationsSection
                    Divider()
                    if programSearch.isEmpty || !filteredCommands.isEmpty { commandsSection }
                    Divider()
                    redirectsSection
                case .profiles:
                    profilesSection
                }
            }
            .padding(20)
        }
        .sheet(item: $editingDomainRule) { rule in
            DomainRuleEditorView(rule: rule, availableTags: store.outboundTags,
                                 routeNames: Dictionary(uniqueKeysWithValues: store.outboundTags.map {
                                     ($0, store.configuration.outboundDisplayName(for: $0))
                                 })) { updated in
                try store.saveDomainRule(updated)
            }
        }
    }

    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                categoryDisclosureButton(isExpanded: $isDomainsExpanded, title: "Domain routes")
                Text("Domain routes").font(.headline)
                Spacer()
                Button("Add domain rule", systemImage: "plus") {
                    editingDomainRule = DomainRouteRule(pattern: "", outboundTag:
                        store.outboundTags.contains("direct") ? "direct" : (store.outboundTags.first ?? ""))
                    isDomainsExpanded = true
                }.disabled(store.outboundTags.isEmpty)
            }
            if isDomainsExpanded {
                TextField("Search domains", text: $domainSearch)
                    .textFieldStyle(.roundedBorder)
                let visible = store.configuration.domainRules
                    .filter { domainSearch.isEmpty || $0.pattern.localizedCaseInsensitiveContains(domainSearch) }
                    .sorted { $0.normalizedPattern < $1.normalizedPattern }
                if visible.isEmpty {
                    Text("For example: *.com → direct, *.blabla.eu → proxy")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visible) { rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { store.configuration.domainRules.first(where: { $0.id == rule.id })?.enabled ?? false },
                            set: { store.setDomainRuleEnabled(rule.id, enabled: $0) }
                        )).labelsHidden()
                        Text(rule.pattern).font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(store.configuration.outboundDisplayName(for: rule.outboundTag))
                        Spacer()
                        Button("Edit") { editingDomainRule = rule }
                        Button(role: .destructive) { store.removeDomainRule(rule.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                Text("Rules apply to every program before its normal route. A blocked program stays blocked. More specific domains win. Install patch 1.14.4-6 to skip process prompts for matching domains. Only IPv4 connections are routed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    Text(store.configuration.outboundDisplayName(for: tag)).tag(DefaultRoute.outbound(tag))
                }
                Text("Только этот Mac").tag(DefaultRoute.localOnly)
                Text("Без сети").tag(DefaultRoute.block)
            }
            .frame(maxWidth: 420)
            Text("Действует для программ без личного или группового профиля, включая выключенные. Общие правила импортированного JSON для них не применяются. В вариантах «Только этот Mac» и «Без сети» localhost остаётся доступен.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("WebKit route", selection: Binding(
                get: { store.selectedWebKitProfileID },
                set: { store.setWebKitProfile($0) }
            )) {
                Text("Follow normal rules").tag(UUID?.none)
                if let selected = store.configuration.webKitProfileID,
                   !store.configuration.profiles.contains(where: { $0.id == selected }) {
                    Text("Missing profile").tag(Optional(selected))
                }
                ForEach(store.configuration.profiles) { profile in
                    Text(profile.displayName).tag(Optional(profile.id))
                }
            }
            .frame(maxWidth: 420)
            Text("The WebKit networking process can serve pages from multiple apps. This profile applies to all of them when no more specific process rule matches. New connections use the changed route; an unpatched engine may restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Ask for a route for unlisted processes", isOn: Binding(
                get: { store.configuration.askUnknownProcesses },
                set: { store.setAskUnknownProcesses($0) }
            ))
            Text("At the first public IPv4 connection of an unlisted app, command or background process. Save route adds a permanent rule in Programs → Saved from route prompts; Use once applies only to this launch. Requires patch 1.14.4-6. After 20 seconds without an answer, the first connection is blocked; the window stays open for later connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func profileEditor(_ profile: RoutingProfile) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if profile.isBuiltIn {
                    Text(AppLanguage.localized(builtInDescription(profile.kind)))
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
                if profile.isBuiltIn {
                    Text(profile.displayName)
                } else {
                    TextField("Название профиля", text: profileBinding(profile, \.name))
                        .textFieldStyle(.plain)
                }
                Spacer()
                Text(profile.isBuiltIn ? AppLanguage.localized("встроенный") :
                     (profile.outboundTag.isEmpty ? AppLanguage.localized("outbound не выбран") : profile.outboundTag))
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
                categoryDisclosureButton(isExpanded: $isRedirectsExpanded, title: "Local redirects")
                Text("Перенаправления во внутреннюю сеть").font(.headline)
                Spacer()
                Button("Добавить правило", systemImage: "plus") {
                    store.addRedirect()
                    isRedirectsExpanded = true
                }
                    .disabled(store.configuration.applications.isEmpty)
            }
            if isRedirectsExpanded {
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
            if let processRouteError {
                Text(processRouteError).font(.caption).foregroundStyle(.red)
            }
            ForEach(store.configuration.groups.filter { group in
                programSearch.isEmpty || group.name.localizedCaseInsensitiveContains(programSearch)
                    || store.configuration.applications.contains { $0.groupID == group.id && applicationMatchesSearch($0, query: programSearch) }
                    || store.configuration.savedProcessRoutes.contains {
                        $0.groupID == group.id && matchesSearch(processName($0), path: $0.executablePath, query: programSearch)
                    }
            }) { group in
                groupCard(group)
            }

            if programSearch.isEmpty || !filteredUngroupedApplications.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    categoryDisclosureButton(isExpanded: $isUngroupedExpanded, title: "Without group")
                    Label("Без группы", systemImage: "square.stack")
                        .font(.headline)
                    Text("\(ungroupedApplications.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    categoryActions(applications: filteredUngroupedApplications, processRoutes: [], currentGroupID: nil)
                    Button("Добавить программы", systemImage: "plus") {
                        isUngroupedExpanded = true
                        chooseApplications(toGroup: nil)
                    }
                }
                if isUngroupedExpanded || !programSearch.isEmpty {
                    ForEach(filteredUngroupedApplications) { application in
                        applicationEditor(application)
                    }
                    if ungroupedApplications.isEmpty {
                        emptyHint("Здесь можно назначить личный профиль или использовать общий маршрут.")
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if programSearch.isEmpty || !filteredSavedProcessRoutes.isEmpty {
            savedProcessCategory
            }
        }
    }

    private var ungroupedApplications: [RoutedApplication] {
        store.configuration.applications.filter { application in
            guard let groupID = application.groupID else { return true }
            return !store.configuration.groups.contains { $0.id == groupID }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filteredUngroupedApplications: [RoutedApplication] {
        ungroupedApplications.filter { applicationMatchesSearch($0, query: programSearch) }
    }

    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                categoryDisclosureButton(isExpanded: $isCommandsExpanded, title: "Terminal commands")
                Text("Команды терминала").font(.headline)
                Spacer()
                Button("Select all found") {
                    selectedCommandIDs.formUnion(filteredCommands.map(\.id))
                }
                .disabled(filteredCommands.isEmpty)
                if !selectedCommandIDs.isEmpty {
                    Button("Delete selected", role: .destructive) {
                        store.removeCommands(ids: selectedCommandIDs)
                        selectedCommandIDs.removeAll()
                    }
                }
                Button("Добавить SSH, curl и nc") {
                    let urls = ["/usr/bin/ssh", "/usr/bin/curl", "/usr/bin/nc"].map(URL.init(fileURLWithPath:))
                    let errors = store.addCommands(at: urls)
                    commandError = errors.isEmpty ? nil : errors.joined(separator: "\n")
                    isCommandsExpanded = true
                }
                Button("Выбрать файлы…", systemImage: "plus") {
                    isCommandsExpanded = true
                    chooseCommands()
                }
            }
            if isCommandsExpanded || !programSearch.isEmpty {
            Text("Правило привязано к исполняемому файлу: оно действует для команды из iTerm, Terminal и других программ. Выберите внешний маршрут; локальные IPv4 можно направить напрямую независимо от него. Для произвольных дочерних процессов iTerm правило автоматически не наследуется.")
                .font(.caption).foregroundStyle(.secondary)
            if let commandError {
                Text(commandError).font(.caption).foregroundStyle(.red)
            }
            ForEach(filteredCommands) { command in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        selectionButton(command.id, in: $selectedCommandIDs)
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
                            Text(profile.displayName).tag(Optional(profile.id))
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
    }

    private var filteredCommands: [RoutedCommand] {
        store.configuration.commands
            .filter { matchesSearch($0.name, path: $0.executablePath, query: programSearch) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseCommands() {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("Выберите исполняемые файлы команд")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return }
        let errors = store.addCommands(at: panel.urls)
        commandError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func chooseCommandReplacement(for command: RoutedCommand) {
        let panel = NSOpenPanel()
        panel.title = String(format: AppLanguage.localized("Найдите команду %@"), command.name)
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commandError = store.relinkCommand(command, to: url)
    }

    private func groupCard(_ group: RoutingGroup) -> some View {
        let query = group.name.localizedCaseInsensitiveContains(programSearch) ? "" : programSearch
        let members = store.configuration.applications
            .filter { $0.groupID == group.id && applicationMatchesSearch($0, query: query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let routes = store.configuration.savedProcessRoutes
            .filter { $0.groupID == group.id && matchesSearch(processName($0), path: $0.executablePath, query: query) }
            .sorted { processName($0).localizedStandardCompare(processName($1)) == .orderedAscending }
        let entries = (members.map(GroupEntry.application) + routes.map(GroupEntry.process))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let isCollapsed = !expandedGroupIDs.contains(group.id) && (programSearch.isEmpty || entries.isEmpty)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if isCollapsed { expandedGroupIDs.insert(group.id) }
                    else { expandedGroupIDs.remove(group.id) }
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
                Text("\(store.configuration.applications.filter { $0.groupID == group.id }.count + store.configuration.savedProcessRoutes.filter { $0.groupID == group.id }.count)")
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
                categoryActions(applications: members, processRoutes: routes, currentGroupID: group.id)
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
                if members.isEmpty && routes.isEmpty { emptyHint("Добавьте программы в группу.") }
                ForEach(entries) { entry in
                    switch entry {
                    case .application(let application): applicationEditor(application)
                    case .process(let route): savedProcessRow(route)
                    }
                }
            }
        }
        .padding(12)
        .background(group.color.displayColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(group.color.displayColor.opacity(0.3)))
    }

    private var filteredSavedProcessRoutes: [SavedProcessRoute] {
        store.configuration.savedProcessRoutes
            .filter { $0.groupID == nil && matchesSearch(processName($0), path: $0.executablePath,
                                                       query: programSearch) }
            .sorted { processName($0).localizedStandardCompare(processName($1)) == .orderedAscending }
    }

    private var savedProcessCategory: some View {
        let routes = filteredSavedProcessRoutes
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                categoryDisclosureButton(isExpanded: $isSavedProcessExpanded, title: "Saved process routes")
                Label("Saved from route prompts", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text("\(store.configuration.savedProcessRoutes.filter { $0.groupID == nil }.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                categoryActions(applications: [], processRoutes: routes, currentGroupID: nil)
            }
            if isSavedProcessExpanded || !programSearch.isEmpty {
            Text("A saved choice applies to future launches of this executable. Move it into a group to use the group's route. Use once in a prompt does not add a rule here.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(routes) { route in savedProcessRow(route) }
            if routes.isEmpty { emptyHint("No saved process routes.") }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func savedProcessRow(_ route: SavedProcessRoute) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                selectionButton(route.id, in: $selectedProcessRouteIDs)
                Image(nsImage: NSWorkspace.shared.icon(forFile: route.executablePath))
                    .resizable().frame(width: 24, height: 24)
                Text(processName(route)).fontWeight(.medium)
                Spacer()
                Toggle("Enable route", isOn: Binding(
                    get: { store.configuration.savedProcessRoutes.first(where: { $0.id == route.id })?.enabled ?? false },
                    set: { store.setProcessRouteEnabled(route.id, enabled: $0) }
                ))
                .labelsHidden()
                .disabled(!FileManager.default.isExecutableFile(atPath: route.executablePath))
                Picker("Category", selection: Binding(
                    get: { store.configuration.savedProcessRoutes.first(where: { $0.id == route.id })?.groupID },
                    set: { store.updateProcessRoutes(ids: [route.id], groupID: $0) }
                )) {
                    Text("Saved from prompts").tag(UUID?.none)
                    ForEach(store.configuration.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .frame(width: 170)
                if route.groupID == nil {
                    Picker("Route", selection: Binding(
                        get: { store.configuration.savedProcessRoutes.first(where: { $0.id == route.id })?.route ?? route.route },
                        set: { store.updateProcessRoutes(ids: [route.id], route: $0) }
                    )) {
                        if case .outbound(let selectedTag) = route.route,
                           !store.outboundTags.contains(selectedTag) {
                            Text("\(selectedTag) · missing").tag(route.route)
                        }
                        ForEach(store.outboundTags, id: \.self) { tag in
                            Text(store.configuration.outboundDisplayName(for: tag)).tag(DefaultRoute.outbound(tag))
                        }
                        Text("This Mac only").tag(DefaultRoute.localOnly)
                        Text("Block public internet").tag(DefaultRoute.block)
                    }
                    .frame(width: 165)
                } else {
                    Text("Uses group route").font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    store.updateProcessRoutes(ids: [route.id], remove: true)
                    selectedProcessRouteIDs.remove(route.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            Text(route.executablePath)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if !FileManager.default.isExecutableFile(atPath: route.executablePath) {
                Button("Locate executable…") { chooseProcessRouteReplacement(for: route) }
                    .font(.caption)
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func categoryActions(applications: [RoutedApplication], processRoutes: [SavedProcessRoute],
                                 currentGroupID: UUID?) -> some View {
        let appIDs = Set(applications.map(\.id))
        let routeIDs = Set(processRoutes.map(\.id))
        let selectedApps = selectedApplicationIDs.intersection(appIDs)
        let selectedRoutes = selectedProcessRouteIDs.intersection(routeIDs)
        return HStack(spacing: 4) {
            Button("Select all found") {
                selectedApplicationIDs.formUnion(appIDs)
                selectedProcessRouteIDs.formUnion(routeIDs)
            }
            .disabled(appIDs.isEmpty && routeIDs.isEmpty)
            if !selectedApps.isEmpty || !selectedRoutes.isEmpty {
                Menu("Selected \(selectedApps.count + selectedRoutes.count)") {
                    Menu("Move to") {
                        if currentGroupID != nil {
                            Button("Without group") {
                                store.updateCategoryItems(applicationIDs: selectedApps,
                                                          processRouteIDs: selectedRoutes,
                                                          groupID: nil, remove: false)
                                selectedApplicationIDs.subtract(selectedApps)
                                selectedProcessRouteIDs.subtract(selectedRoutes)
                            }
                        }
                        ForEach(store.configuration.groups.filter { $0.id != currentGroupID }) { group in
                            Button(group.name) {
                                store.updateCategoryItems(applicationIDs: selectedApps,
                                                          processRouteIDs: selectedRoutes,
                                                          groupID: group.id, remove: false)
                                selectedApplicationIDs.subtract(selectedApps)
                                selectedProcessRouteIDs.subtract(selectedRoutes)
                            }
                        }
                    }
                    Button("Delete selected", role: .destructive) {
                        store.updateCategoryItems(applicationIDs: selectedApps,
                                                  processRouteIDs: selectedRoutes,
                                                  groupID: nil, remove: true)
                        selectedApplicationIDs.subtract(selectedApps)
                        selectedProcessRouteIDs.subtract(selectedRoutes)
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func categoryDisclosureButton(isExpanded: Binding<Bool>, title: String) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    private func selectionButton(_ id: UUID, in selection: Binding<Set<UUID>>) -> some View {
        Button {
            var value = selection.wrappedValue
            if value.contains(id) { value.remove(id) } else { value.insert(id) }
            selection.wrappedValue = value
        } label: {
            Image(systemName: selection.wrappedValue.contains(id) ? "checkmark.square.fill" : "square")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection.wrappedValue.contains(id) ? "Deselect" : "Select")
    }

    private func processName(_ route: SavedProcessRoute) -> String {
        URL(fileURLWithPath: route.executablePath).lastPathComponent
    }

    private func chooseProcessRouteReplacement(for route: SavedProcessRoute) {
        let panel = NSOpenPanel()
        panel.title = String(format: AppLanguage.localized("Locate %@"), processName(route))
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        processRouteError = store.relinkProcessRoute(route.id, to: url)
    }

    private func matchesSearch(_ name: String, path: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || name.localizedStandardContains(trimmed) || path.localizedStandardContains(trimmed)
    }

    private func applicationMatchesSearch(_ application: RoutedApplication, query: String) -> Bool {
        matchesSearch(application.name, path: application.executablePath, query: query)
            || store.configuration.childCommandChoices.contains {
                $0.applicationID == application.id
                    && matchesSearch(URL(fileURLWithPath: $0.executablePath).lastPathComponent,
                                     path: $0.executablePath, query: query)
            }
    }

    private func groupEditor(_ group: RoutingGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Изменить группу").font(.headline)
            TextField("Название группы", text: groupBinding(group, \.name))
            Picker("Цвет", selection: groupBinding(group, \.color)) {
                ForEach(RoutingGroupColor.allCases, id: \.self) { color in
                    Text(AppLanguage.localized(color.title)).tag(color)
                }
            }
            Picker("Маршрут", selection: groupBinding(group, \.profileID)) {
                Text("Общий маршрут").tag(UUID?.none)
                ForEach(store.configuration.profiles) { profile in
                    Text(profile.displayName).tag(Optional(profile.id))
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
        return profile.displayName
    }

    private var defaultRouteTitle: String {
        switch store.selectedDefaultRoute {
        case .outbound(let tag): return "Общий · \(store.configuration.outboundDisplayName(for: tag))"
        case .localOnly: return "Общий · Только этот Mac"
        case .block: return "Общий · Без сети"
        }
    }

    private func applicationEditor(_ application: RoutedApplication) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                selectionButton(application.id, in: $selectedApplicationIDs)
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(application.name).fontWeight(.medium)
                Spacer()
                Toggle("Enable route", isOn: applicationBinding(application, \.enabled))
                    .labelsHidden()
                    .help("Enable routing for this application")
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
                            Text(profile.displayName).tag(Optional(profile.id))
                        }
                    }
                }
                Toggle("Запускать после готовности сети", isOn: applicationBinding(application, \.launchAfterEngineReady))
            }
            .controlSize(.small)

            Toggle("Доступ к локальной сети напрямую", isOn: applicationBinding(application, \.allowLocalNetwork))
                .controlSize(.small)
                .help("Для этой программы локальные IPv4 идут через сеть Mac при любом выбранном маршруте. Публичные адреса следуют маршруту программы или группы.")

            if application.bundleIdentifier != RoutingStore.selfBundleIdentifier {
                Toggle("Спрашивать маршрут для дочерних команд", isOn: applicationBinding(application, \.askChildCommands))
                    .controlSize(.small)
                if application.askChildCommands {
                    Text("Команды по умолчанию наследуют маршрут программы. При первом внешнем IPv4-соединении неизвестной команды IP Informer предложит выбрать маршрут и запомнит его.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(store.configuration.childCommandChoices
                        .filter { $0.applicationID == application.id }
                        .sorted { URL(fileURLWithPath: $0.executablePath).lastPathComponent.localizedStandardCompare(
                            URL(fileURLWithPath: $1.executablePath).lastPathComponent) == .orderedAscending }) { choice in
                        HStack {
                            Text(URL(fileURLWithPath: choice.executablePath).lastPathComponent)
                                .font(.caption.monospaced())
                            Picker("Маршрут", selection: Binding(
                                get: { store.configuration.childCommandChoices.first(where: { $0.id == choice.id })?.route ?? choice.route },
                                set: { store.saveChildCommandChoice(applicationID: application.id,
                                                                     executablePath: choice.executablePath, route: $0) }
                            )) {
                                ForEach(store.outboundTags, id: \.self) { tag in
                                    Text(store.configuration.outboundDisplayName(for: tag)).tag(DefaultRoute.outbound(tag))
                                }
                                Text("Только этот Mac").tag(DefaultRoute.localOnly)
                                Text("Без сети").tag(DefaultRoute.block)
                            }
                            Button(role: .destructive) { store.removeChildCommandChoice(choice) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                        .controlSize(.small)
                    }
                }
            }

        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chooseApplications(toGroup groupID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("Выберите программы")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let errors = store.addApplications(at: panel.urls, toGroup: groupID)
        addError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func chooseReplacement(for application: RoutedApplication) {
        let panel = NSOpenPanel()
        panel.title = String(format: AppLanguage.localized("Найдите %@"), application.name)
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
