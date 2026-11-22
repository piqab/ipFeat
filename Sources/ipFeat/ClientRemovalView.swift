import AppKit
import SwiftUI

private enum ClientRemovalMode {
    case local, serverAndLocal
}

struct ClientRemovalView: View {
    @ObservedObject var store: RoutingStore
    let connection: ClientConnection
    @Environment(\.dismiss) private var dismiss
    @StateObject private var logModel = ServerDeploymentLogModel()

    @State private var replacementProfileID: UUID
    @State private var sshAuthentication = "password"
    @State private var sshUser = "root"
    @State private var sshPort = "22"
    @State private var identityFile = ""
    @State private var rootPassword = ""
    @State private var status = ""
    @State private var isBusy = false
    @State private var isRemoved = false
    @State private var showConfirmation = false
    @State private var showLog = false
    @State private var pendingMode: ClientRemovalMode?

    init(store: RoutingStore, connection: ClientConnection) {
        self.store = store
        self.connection = connection
        let choices = store.configuration.profiles.filter {
            $0.kind != .localNetwork && !($0.kind == .outbound && $0.outboundTag == connection.outboundTag)
        }
        let initial = choices.first(where: { $0.outboundTag == "proxy" && $0.kind == .outbound })
            ?? choices.first(where: { $0.outboundTag == "direct" && $0.kind == .outbound })
            ?? choices.first(where: { $0.kind == .localOnly }) ?? choices.first
        _replacementProfileID = State(initialValue: initial?.id ?? RoutingProfile.block.id)
    }

    private var choices: [RoutingProfile] {
        store.configuration.profiles.filter {
            $0.kind != .localNetwork && !($0.kind == .outbound && $0.outboundTag == connection.outboundTag)
        }
    }

    private var assignments: String {
        let removedIDs = Set(store.configuration.profiles.filter {
            $0.kind == .outbound && $0.outboundTag == connection.outboundTag
        }.map(\.id))
        let groups = store.configuration.groups.filter { $0.profileID.map(removedIDs.contains) == true }.map(\.name)
        let apps = store.configuration.applications.filter { $0.profileID.map(removedIDs.contains) == true }.map(\.name)
        let commands = store.configuration.commands.filter { $0.profileID.map(removedIDs.contains) == true }.map(\.name)
        var parts: [String] = []
        if store.selectedDefaultRoute == .outbound(connection.outboundTag) { parts.append("общий маршрут") }
        if store.configuration.webKitProfileID.map(removedIDs.contains) == true ||
           (store.configuration.webKitProxyEnabled && connection.outboundTag == "proxy") {
            parts.append("WebKit")
        }
        if !groups.isEmpty { parts.append("группы: \(groups.joined(separator: ", "))") }
        if !apps.isEmpty { parts.append("программы: \(apps.joined(separator: ", "))") }
        if !commands.isEmpty { parts.append("команды: \(commands.joined(separator: ", "))") }
        return parts.isEmpty ? "Активных назначений нет." : "Используют подключение: \(parts.joined(separator: "; "))."
    }

    private var managementTrafficUsesThisServer: Bool {
        if store.selectedDefaultRoute == .outbound(connection.outboundTag) { return true }
        if store.configuration.commands.contains(where: { command in
            guard command.enabled, ["ssh", "scp"].contains(URL(fileURLWithPath: command.executablePath).lastPathComponent),
                  let profileID = command.profileID,
                  let profile = store.configuration.profiles.first(where: { $0.id == profileID }) else { return false }
            return profile.kind == .outbound && profile.outboundTag == connection.outboundTag
        }) { return true }
        guard let ownApp = store.configuration.applications.first(where: {
            $0.bundleIdentifier == RoutingStore.selfBundleIdentifier
        }) else { return false }
        return store.effectiveOutboundTag(for: ownApp) == connection.outboundTag
    }

    private var outboundMissing: Bool {
        !store.outboundTags.contains(connection.outboundTag)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Удалить сервер \(connection.name)").font(.title2.weight(.semibold))
            Text("\(connection.serverIPv4) · \(connection.protocolName) · \(connection.outboundTag)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(assignments).font(.caption)
            if outboundMissing {
                Text("Outbound \(connection.outboundTag) не найден в текущем JSON. Запись на Mac и службу на VPS всё равно можно удалить.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Новый маршрут для назначений", selection: $replacementProfileID) {
                ForEach(choices) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
            Text("При удалении клиентского подключения эти назначения перейдут на выбранный маршрут. Конфигурация sing-box будет применена заново.")
                .font(.caption).foregroundStyle(.secondary)
            if managementTrafficUsesThisServer {
                Text("Перед удалением с VPS ipFeat переключит использующие этот сервер маршруты на выбранный маршрут, чтобы SSH-соединение не оборвалось.")
                    .font(.caption).foregroundStyle(.orange)
            }

            GroupBox("Доступ для удаления на VPS") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Способ входа", selection: $sshAuthentication) {
                        Text("Пароль root").tag("password")
                        Text("SSH-ключ").tag("key")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("SSH-порт", text: $sshPort).frame(width: 100)
                        if sshAuthentication == "password" {
                            SecureField("Пароль root", text: $rootPassword)
                            Text("Пользователь: root").foregroundStyle(.secondary)
                        } else {
                            TextField("Пользователь", text: $sshUser).frame(width: 150)
                            TextField("Путь к SSH-ключу", text: $identityFile)
                            Button("Выбрать…") { chooseKey() }
                        }
                    }
                    Text("ipFeat удалит только свою службу и каталоги после проверки файла службы. Пароль не сохраняется.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .disabled(isBusy || isRemoved)

            if !status.isEmpty {
                Text(status).font(.caption)
                    .foregroundStyle(status.hasPrefix("Ошибка") ? .red : .secondary)
            }
            HStack {
                if !logModel.text.isEmpty { Button("Лог удаления") { showLog = true } }
                Spacer()
                Button("Закрыть") { dismiss() }.disabled(isBusy)
                Button("Удалить только с Mac", role: .destructive) { confirm(.local) }
                    .disabled(isBusy || isRemoved)
                Button("Удалить с VPS и Mac", role: .destructive) { confirm(.serverAndLocal) }
                    .disabled(isBusy || isRemoved ||
                              (sshAuthentication == "password" ? rootPassword.isEmpty : identityFile.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 700)
        .confirmationDialog("Подтвердите удаление \(connection.name)", isPresented: $showConfirmation) {
            if let pendingMode {
                Button(pendingMode == .local ? "Удалить только с Mac" : "Удалить с VPS и Mac", role: .destructive) {
                    switch pendingMode {
                    case .local: removeLocally()
                    case .serverAndLocal: Task { await removeFromServerAndMac() }
                    }
                }
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text(pendingMode == .local
                 ? "Служба на VPS продолжит работать."
                 : "Служба на VPS будет остановлена и удалена. Затем подключение исчезнет с Mac.")
        }
        .sheet(isPresented: $showLog) {
            ServerDeploymentLogView(model: logModel, title: "Удаление sing-box с VPS")
        }
    }

    private func confirm(_ mode: ClientRemovalMode) {
        pendingMode = mode
        showConfirmation = true
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Выберите SSH-ключ для VPS"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityFile = url.path
    }

    private func removeLocally() {
        do {
            let wasMissing = outboundMissing
            try store.removeClientConnection(connection.id, replacementProfileID: replacementProfileID)
            isRemoved = true
            status = wasMissing
                ? "Outbound уже отсутствовал в JSON. Запись удалена с Mac; служба на VPS сохранена."
                : "Подключение удалено с Mac и из текущего JSON. Служба на VPS сохранена."
        } catch {
            status = "Ошибка удаления: \(error.localizedDescription)"
        }
    }

    private func removeFromServerAndMac() async {
        do {
            try store.previewClientRemoval(connection.id, replacementProfileID: replacementProfileID)
        } catch {
            status = "Ошибка проверки маршрутов: \(error.localizedDescription)"
            return
        }
        guard let port = Int(sshPort), (1...65535).contains(port) else {
            status = "Ошибка: неверный SSH-порт"
            return
        }
        let shouldReroute = managementTrafficUsesThisServer
        if shouldReroute {
            guard store.configuration.profiles.contains(where: {
                $0.id == replacementProfileID && $0.kind == .outbound && $0.outboundTag != connection.outboundTag
            }) else {
                status = "Ошибка: для SSH выберите работающий сетевой маршрут вместо этого сервера"
                return
            }
        }
        let authentication: ServerSSHAuthentication = sshAuthentication == "password"
            ? .rootPassword(rootPassword) : .key(identityFile)
        let access = ServerSSHSettings(host: connection.serverIPv4,
                                       user: sshAuthentication == "password" ? "root" : sshUser,
                                       port: port, authentication: authentication)
        isBusy = true
        status = "Удаление службы на VPS…"
        logModel.reset()
        showLog = true
        logModel.append("Удаление сервера \(connection.name) на \(connection.serverIPv4)\n")
        if outboundMissing {
            logModel.append("Outbound \(connection.outboundTag) уже отсутствует в текущем JSON; это не мешает удалению с VPS.\n")
        }
        if shouldReroute {
            do {
                try store.rerouteBeforeServerRemoval(connection.id, replacementProfileID: replacementProfileID)
                logModel.append("Маршруты переключены на выбранный профиль до SSH.\n")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                status = "Ошибка переключения маршрута: \(error.localizedDescription)"
                logModel.append("\nОШИБКА: \(error.localizedDescription)\n")
                logModel.finish()
                isBusy = false
                return
            }
        }
        let model = logModel
        let report: ServerDeployment.Log = { chunk in
            DispatchQueue.main.async { model.append(chunk) }
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ServerDeployment.uninstall(access: access, log: report) }
        }.value
        rootPassword = ""
        var finalLog: String
        switch result {
        case .failure(let error):
            status = "Ошибка удаления на VPS: \(error.localizedDescription). Подключение на Mac сохранено."
                + (shouldReroute ? " Маршруты уже переключены на выбранный профиль." : "")
            finalLog = "\nОШИБКА: \(error.localizedDescription)\n"
        case .success:
            do {
                try store.removeClientConnection(connection.id, replacementProfileID: replacementProfileID)
                isRemoved = true
                status = "Служба на VPS и подключение на Mac удалены."
                finalLog = "\nСлужба на VPS и подключение на Mac удалены.\n"
            } catch {
                status = "Ошибка: служба на VPS удалена, но подключение на Mac осталось: \(error.localizedDescription)"
                finalLog = "\nОШИБКА удаления локального подключения: \(error.localizedDescription)\n"
            }
        }
        isBusy = false
        DispatchQueue.main.async {
            model.append(finalLog)
            model.finish()
        }
    }
}
