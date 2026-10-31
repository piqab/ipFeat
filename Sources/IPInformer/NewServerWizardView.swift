import AppKit
import SwiftUI

struct NewServerWizardView: View {
    @ObservedObject var store: RoutingStore
    @StateObject private var engine = EngineManager()
    @StateObject private var deploymentLog = ServerDeploymentLogModel()
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Новый сервер"
    @State private var host = ""
    @State private var servicePort = "443"
    @State private var handshakeHost = ""
    @State private var sshUser = "root"
    @State private var sshPort = "22"
    @State private var identityFile = ""
    @State private var sshAuthentication = "password"
    @State private var rootPassword = ""
    @State private var configurationVersion: String?
    @State private var validatedVersion: String?
    @State private var protocolID = "inbound:vless"
    @State private var options: [ServerProtocolOption] = []
    @State private var serverJSON = ""
    @State private var clientJSON = ""
    @State private var status = ""
    @State private var isDeploying = false
    @State private var showDeploymentLog = false
    @State private var validated = false

    private var selectedOption: ServerProtocolOption? { options.first { $0.id == protocolID } }
    private var binary: String? { NewServerConfiguration.availableBinary() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Новый сервер sing-box").font(.title2.weight(.semibold))
                Spacer()
                Text("Версия \(engine.installedVersion ?? "не установлена")")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Подключение") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Название", text: $name)
                                TextField("Публичный IPv4 VPS", text: $host)
                                TextField("Порт sing-box", text: $servicePort).frame(width: 135)
                            }
                            HStack {
                                Picker("Технология", selection: $protocolID) {
                                    ForEach(options) { option in
                                        Text("\(option.kind.rawValue) · \(option.name)").tag(option.id)
                                    }
                                }
                                .frame(width: 270)
                                if selectedOption?.name == "vless" {
                                    TextField("Домен TLS-сайта для Reality", text: $handshakeHost)
                                }
                            }
                            if let option = selectedOption {
                                Text(option.isAutomatic
                                     ? "Для этого протокола ключи и параметры пары создаются автоматически."
                                     : "Расширенный режим по схеме этой версии: заполните оба JSON. Поля: \(option.fields.joined(separator: ", ")). Некоторые технологии не образуют пару клиент–сервер.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Создать черновики клиента и сервера") { generate() }
                                .disabled(binary == nil || host.isEmpty)
                        }
                        .padding(6)
                    }
                    GroupBox("SSH-доступ к новому VPS") {
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
                                    TextField("Пользователь", text: $sshUser).frame(width: 180)
                                    TextField("Путь к SSH-ключу", text: $identityFile)
                                    Button("Выбрать…") { chooseKey() }
                                }
                            }
                            Text("Пароль root используется только для установки и не сохраняется. На VPS должен быть разрешён вход root по SSH с паролем. SSH-ключ VPS сохраняется в known_hosts; изменившийся ключ отклоняется. Мастер проверит Linux и systemd и не заменит существующий сервер IP Informer.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }
                    if !serverJSON.isEmpty || !clientJSON.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading) {
                                Text("Серверный JSON").font(.headline)
                                TextEditor(text: $serverJSON)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 240)
                                    .border(Color.secondary.opacity(0.3))
                            }
                            VStack(alignment: .leading) {
                                Text("Клиентский outbound").font(.headline)
                                TextEditor(text: $clientJSON)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 240)
                                    .border(Color.secondary.opacity(0.3))
                            }
                        }
                        .onChange(of: serverJSON) { _ in validated = false }
                        .onChange(of: clientJSON) { _ in validated = false }
                    }
                }
            }
            .disabled(isDeploying)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(status.hasPrefix("Ошибка") ? .red : .secondary) }
            HStack {
                Button("Закрыть") { dismiss() }.disabled(isDeploying)
                if !deploymentLog.text.isEmpty {
                    Button("Лог установки") { showDeploymentLog = true }
                }
                Spacer()
                Button("Проверить оба конфига") { validate() }
                    .disabled(serverJSON.isEmpty || clientJSON.isEmpty || binary == nil || isDeploying)
                Button("Установить на VPS и добавить клиент") { Task { await deploy() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!validated || isDeploying || (sshAuthentication == "password" ? rootPassword.isEmpty : identityFile.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 960, height: 720)
        .onChange(of: host) { _ in validated = false }
        .onChange(of: servicePort) { _ in validated = false }
        .onChange(of: protocolID) { _ in validated = false }
        .onChange(of: handshakeHost) { _ in validated = false }
        .sheet(isPresented: $showDeploymentLog) { ServerDeploymentLogView(model: deploymentLog) }
        .onAppear {
            engine.refreshLocalState()
            if let binary {
                do { options = try NewServerConfiguration.protocolOptions(binary: binary) }
                catch { status = "Ошибка схемы: \(error.localizedDescription)" }
            }
            Task { await engine.refreshReleases() }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Выберите SSH-ключ для нового VPS"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityFile = url.path
    }

    private func generate() {
        guard let binary, let port = Int(servicePort), let option = selectedOption else {
            status = "Ошибка: некорректный порт или sing-box не установлен"
            return
        }
        do {
            engine.refreshLocalState()
            let version = try NewServerConfiguration.binaryVersion(binary: binary)
            guard version == engine.installedVersion else {
                throw NSError(domain: "IPInformer", code: 24, userInfo: [NSLocalizedDescriptionKey: "Версия бинарника sing-box не совпадает с установленной версией. Обновите состояние движка."])
            }
            let pair = try NewServerConfiguration.generate(
                name: name, serverIPv4: host, port: port,
                protocolName: option.name, handshakeHost: handshakeHost, kind: option.kind, binary: binary
            )
            serverJSON = pair.serverConfigurationJSON
            clientJSON = pair.clientOutboundJSON
            configurationVersion = version
            validatedVersion = nil
            status = selectedOption?.isAutomatic == true
                ? "Черновики созданы; проверьте параметры" : "Черновики созданы; заполните обязательные поля выбранной технологии"
            validated = false
        } catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func validate() {
        guard let binary else { return }
        engine.refreshLocalState()
        do {
            guard let version = engine.installedVersion, version == configurationVersion else {
                throw NSError(domain: "IPInformer", code: 22, userInfo: [NSLocalizedDescriptionKey: "Версия sing-box изменилась. Создайте конфиги заново для текущей версии."])
            }
            guard try NewServerConfiguration.binaryVersion(binary: binary) == version else {
                throw NSError(domain: "IPInformer", code: 24, userInfo: [NSLocalizedDescriptionKey: "Исполняемый sing-box не соответствует версии конфигов"])
            }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "IPInformer", code: 21, userInfo: [NSLocalizedDescriptionKey: "Укажите название подключения"])
            }
            try NewServerConfiguration.validatePairing(serverJSON: serverJSON, outboundJSON: clientJSON,
                                                       serverIPv4: host, port: Int(servicePort) ?? 0,
                                                       option: selectedOption)
            try NewServerConfiguration.validate(serverJSON: serverJSON,
                                                outboundJSON: clientJSON, binary: binary)
            validated = true
            validatedVersion = version
            status = "Оба конфига приняты sing-box \(version)"
        } catch {
            validated = false
            status = "Ошибка проверки: \(error.localizedDescription)"
        }
    }

    private func deploy() async {
        engine.refreshLocalState()
        guard validated, let version = validatedVersion, version == configurationVersion,
              version == engine.installedVersion,
              let release = engine.releases.first(where: { $0.version == version }),
              let sshPort = Int(sshPort), let binary else {
            status = "Ошибка: версия sing-box изменилась, выпуск недоступен или неверный SSH-порт. Проверьте конфиги заново."
            return
        }
        do {
            guard try NewServerConfiguration.binaryVersion(binary: binary) == version else {
                throw NSError(domain: "IPInformer", code: 24, userInfo: [NSLocalizedDescriptionKey: "Исполняемый sing-box изменился после проверки конфигов"])
            }
            try NewServerConfiguration.validatePairing(serverJSON: serverJSON, outboundJSON: clientJSON,
                                                       serverIPv4: host, port: Int(servicePort) ?? 0,
                                                       option: selectedOption)
            try NewServerConfiguration.validate(serverJSON: serverJSON, outboundJSON: clientJSON, binary: binary)
            guard let outbound = try JSONSerialization.jsonObject(with: Data(clientJSON.utf8)) as? [String: Any],
                  let actualTag = outbound["tag"] as? String,
                  let actualType = outbound["type"] as? String else {
                throw NSError(domain: "IPInformer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Клиентский outbound повреждён"])
            }
            let candidate = ClientConnection(name: name, outboundTag: actualTag,
                                             serverIPv4: host, protocolName: actualType,
                                             singBoxVersion: release.version)
            try store.previewClientConnection(candidate, outboundJSON: clientJSON)
        } catch {
            validated = false
            status = "Ошибка проверки: \(error.localizedDescription)"
            return
        }
        isDeploying = true
        status = "Проверка SSH и установка сервера…"
        deploymentLog.reset()
        showDeploymentLog = true
        deploymentLog.append("Начало установки на \(host), sing-box \(version)\n")
        let authentication: ServerSSHAuthentication = sshAuthentication == "password"
            ? .rootPassword(rootPassword) : .key(identityFile)
        let access = ServerSSHSettings(host: host, user: sshAuthentication == "password" ? "root" : sshUser,
                                       port: sshPort, authentication: authentication)
        let server = serverJSON
        let client = clientJSON
        let connectionName = name
        let serverHost = host
        let logModel = deploymentLog
        let report: ServerDeployment.Log = { chunk in
            DispatchQueue.main.async { logModel.append(chunk) }
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ServerDeployment.deploy(configuration: server, release: release, access: access, log: report) }
        }.value
        rootPassword = ""
        var finalLog: String
        switch result {
        case .failure(let error):
            status = "Ошибка установки: \(error.localizedDescription)"
            finalLog = "\nОШИБКА: \(error.localizedDescription)\n"
        case .success(let output):
            do {
                guard let data = client.data(using: .utf8),
                      let outbound = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let actualTag = outbound["tag"] as? String,
                      let actualType = outbound["type"] as? String else {
                    throw NSError(domain: "IPInformer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Клиентский JSON повреждён"])
                }
                let connection = ClientConnection(name: connectionName, outboundTag: actualTag,
                                                  serverIPv4: serverHost, protocolName: actualType,
                                                  singBoxVersion: release.version)
                try store.registerClientConnection(connection, outboundJSON: client,
                                                   serverConfiguration: server)
                status = "\(output). Клиент \(connectionName) добавлен в библиотеку."
                finalLog = "\nКлиент \(connectionName) добавлен в библиотеку.\n"
            } catch {
                status = "Сервер установлен, но клиент не добавлен: \(error.localizedDescription)"
                finalLog = "\nОШИБКА добавления клиента: \(error.localizedDescription)\n"
            }
        }
        isDeploying = false
        DispatchQueue.main.async {
            logModel.append(finalLog)
            logModel.finish()
        }
    }
}
