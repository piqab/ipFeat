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
    @State private var tlsMode = "acme"
    @State private var tlsDomain = ""
    @State private var tlsEmail = ""
    @State private var certificatePEM = ""
    @State private var keyPEM = ""
    @State private var certificateName = ""
    @State private var keyName = ""
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
    @State private var manualArchitecture = "amd64"
    @State private var pendingInstallation: PendingServerInstallation?
    @State private var manualResult = ""

    private var selectedOption: ServerProtocolOption? { options.first { $0.id == protocolID } }
    private var binary: String? { NewServerConfiguration.availableBinary() }
    private var requiresTLS: Bool { ["trojan", "hysteria2", "anytls"].contains(selectedOption?.name ?? "") }

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
                                        Text(option.name + (option.isAutomatic ? "" : " · вручную")).tag(option.id)
                                    }
                                }
                                .frame(width: 270)
                                if selectedOption?.name == "vless" {
                                    TextField("Домен TLS-сайта для Reality", text: $handshakeHost)
                                }
                            }
                            if requiresTLS {
                                Picker("Сертификат TLS", selection: $tlsMode) {
                                    Text("ACME").tag("acme")
                                    Text("PEM-файлы").tag("pem")
                                }
                                .pickerStyle(.segmented)
                                TextField("Домен сервера TLS", text: $tlsDomain)
                                if tlsMode == "acme" {
                                    TextField("Email для ACME", text: $tlsEmail)
                                    Text("DNS A-запись домена должна вести на публичный IPv4 VPS. Откройте на VPS порты 80 и 443 для получения сертификата ACME; для Hysteria2 откройте также выбранный UDP-порт.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    HStack {
                                        Button("Выбрать сертификат PEM…") { choosePEM(certificate: true) }
                                        Text(certificateName.isEmpty ? "Не выбран" : certificateName)
                                        Button("Выбрать закрытый ключ PEM…") { choosePEM(certificate: false) }
                                        Text(keyName.isEmpty ? "Не выбран" : keyName)
                                    }
                                    Text("PEM будет встроен в серверный JSON; сертификат также войдёт в клиентский outbound для проверки TLS. Отдельные файлы на VPS не потребуются.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let option = selectedOption {
                                Text(option.isAutomatic
                                     ? "Для этого протокола ключи и параметры пары создаются автоматически."
                                     : "Ручной режим: черновики содержат только адрес и тип. Добавьте обязательные поля в оба JSON и проверьте их локально. Поля: \(option.fields.joined(separator: ", ")).")
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
                    if validated { manualInstallationSection }
                }
            }
            .disabled(isDeploying)
            if !status.isEmpty {
                Text(status).font(.caption)
                    .foregroundStyle(status.hasPrefix("Ошибка") || status.hasPrefix(AppLanguage.localized("Ошибка")) ? .red : .secondary)
            }
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
        .onChange(of: tlsMode) { _ in validated = false }
        .onChange(of: tlsDomain) { _ in validated = false }
        .onChange(of: tlsEmail) { _ in validated = false }
        .sheet(isPresented: $showDeploymentLog) { ServerDeploymentLogView(model: deploymentLog) }
        .onAppear {
            engine.refreshLocalState()
            if let binary {
                do { options = try NewServerConfiguration.protocolOptions(binary: binary).filter { $0.kind == .inbound && $0.hasClientOutbound } }
                catch { status = "Ошибка схемы: \(error.localizedDescription)" }
            }
        }
    }

    private var manualInstallationSection: some View {
        GroupBox("Manual VPS installation") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("VPS architecture", selection: $manualArchitecture) {
                    Text("x86_64 / amd64").tag("amd64")
                    Text("aarch64 / arm64").tag("arm64")
                }
                .frame(maxWidth: 300)
                Text("Run the copied script as root on the VPS, or export a package for a Mac/Linux host that can connect to the VPS. The host script downloads and verifies the Linux archive before transferring it. The scripts contain server credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy server installation script") { copyManualScript() }
                    Button("Copy host installation script") { copyHostScript() }
                    Button("Export installation package…") { exportManualPackage() }
                }
                TextField("Paste IPINFORMER_INSTALL_OK line after installation", text: $manualResult)
                    .textFieldStyle(.roundedBorder)
                Button("Match result and add client") { completeManualInstallation() }
                    .disabled(manualResult.isEmpty || pendingInstallation == nil)
            }
            .padding(6)
        }
    }

    private func preparePendingInstallation() throws -> PendingServerInstallation {
        guard validated, let version = validatedVersion, version == configurationVersion,
              let binary, try NewServerConfiguration.binaryVersion(binary: binary) == version,
              let port = Int(sshPort), (1...65535).contains(port),
              let outbound = try JSONSerialization.jsonObject(with: Data(clientJSON.utf8)) as? [String: Any],
              let tag = outbound["tag"] as? String,
              let type = outbound["type"] as? String else {
            throw NSError(domain: "IPInformer.ManualInstall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Check both JSON files and the sing-box version again"])
        }
        try NewServerConfiguration.validatePairing(serverJSON: serverJSON, outboundJSON: clientJSON,
                                                   serverIPv4: host, port: Int(servicePort) ?? 0,
                                                   option: selectedOption)
        try NewServerConfiguration.validate(serverJSON: serverJSON, outboundJSON: clientJSON, binary: binary)
        if let pendingInstallation, pendingInstallation.serverJSON == serverJSON,
           pendingInstallation.clientJSON == clientJSON, pendingInstallation.architecture == manualArchitecture,
           pendingInstallation.serverIPv4 == host, pendingInstallation.version == version,
           pendingInstallation.name == name, pendingInstallation.sshPort == port {
            return pendingInstallation
        }
        let pending = PendingServerInstallation(id: UUID(), name: name, serverIPv4: host,
            sshPort: port, architecture: manualArchitecture, version: version,
            protocolName: type, outboundTag: tag, clientJSON: clientJSON,
            serverJSON: serverJSON, createdAt: Date())
        try PendingServerInstallationStore.save(pending)
        pendingInstallation = pending
        return pending
    }

    private func copyManualScript() {
        do {
            let pending = try preparePendingInstallation()
            let script = try pending.serverScript()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(script, forType: .string)
            status = "Server installer copied. Run it as root; paste its IPINFORMER_INSTALL_OK result here."
        } catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func copyHostScript() {
        do {
            let pending = try preparePendingInstallation()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(try pending.hostScript(), forType: .string)
            status = "Standalone host installer copied. It contains server credentials."
        } catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func exportManualPackage() {
        do {
            let pending = try preparePendingInstallation()
            let panel = NSOpenPanel()
            panel.title = "Choose a private folder for the installation package"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let parent = panel.url else { return }
            let destination = parent.appendingPathComponent("IPInformer-Server-\(pending.id.uuidString.prefix(8))")
            try pending.writePackage(to: destination)
            status = "Installation package saved: \(destination.path)"
        } catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func completeManualInstallation() {
        guard let pendingInstallation else { return }
        do {
            try store.completePendingServerInstallation(pendingInstallation, result: manualResult)
            status = "Result matched; client \(pendingInstallation.name) added as not yet verified on the VPS."
            self.pendingInstallation = nil
            manualResult = ""
        } catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("Выберите SSH-ключ для нового VPS")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityFile = url.path
    }

    private func choosePEM(certificate: Bool) {
        let panel = NSOpenPanel()
        panel.title = certificate
            ? AppLanguage.localized("Выберите сертификат TLS в PEM")
            : AppLanguage.localized("Выберите закрытый ключ TLS в PEM")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000, let pem = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "IPInformer", code: 26, userInfo: [NSLocalizedDescriptionKey: "Ожидается текстовый PEM-файл размером до 1 МБ"])
            }
            if certificate { certificatePEM = pem; certificateName = url.lastPathComponent }
            else { keyPEM = pem; keyName = url.lastPathComponent }
            validated = false
            status = "PEM-файл загружен: \(url.lastPathComponent)"
        } catch { status = "Ошибка PEM: \(error.localizedDescription)" }
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
            let tlsSource: ServerTLSSource? = requiresTLS
                ? (tlsMode == "acme" ? .acme(domain: tlsDomain, email: tlsEmail)
                   : .certificate(domain: tlsDomain, certificatePEM: certificatePEM, keyPEM: keyPEM))
                : nil
            let pair = try NewServerConfiguration.generate(
                name: name, serverIPv4: host, port: port,
                protocolName: option.name, handshakeHost: handshakeHost, kind: option.kind, binary: binary,
                tlsSource: tlsSource
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
        guard !isDeploying else { return }
        engine.refreshLocalState()
        guard validated, let version = validatedVersion, version == configurationVersion else {
            status = AppLanguage.localized("Ошибка: конфиги нужно проверить заново перед установкой.")
            return
        }
        guard version == engine.installedVersion else {
            validated = false
            status = String(format: AppLanguage.localized("Ошибка: версия sing-box изменилась с %@ на %@. Создайте и проверьте конфиги заново."),
                            version, engine.installedVersion ?? AppLanguage.localized("не установлена"))
            return
        }
        guard let binary else {
            status = AppLanguage.localized("Ошибка: исполняемый sing-box не найден на этом Mac.")
            return
        }
        guard let sshPort = Int(sshPort), (1...65535).contains(sshPort) else {
            status = AppLanguage.localized("Ошибка: SSH-порт должен быть числом от 1 до 65535.")
            return
        }
        let pending: PendingServerInstallation
        do { pending = try preparePendingInstallation() }
        catch { status = "Ошибка: \(error.localizedDescription)"; return }
        isDeploying = true
        defer { isDeploying = false }
        status = "Проверка конфигов и подключение к VPS…"
        deploymentLog.reset()
        showDeploymentLog = true
        deploymentLog.append(status + "\n")
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
                                             singBoxVersion: version)
            try store.previewClientConnection(candidate, outboundJSON: clientJSON)
        } catch {
            validated = false
            status = "Ошибка проверки: \(error.localizedDescription)"
            deploymentLog.append(status + "\n")
            deploymentLog.finish()
            return
        }
        status = "Проверка SSH и установка сервера…"
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
            Result { try ServerDeployment.deploy(configuration: server, version: version, access: access, log: report) }
        }.value
        let verification = await Task.detached(priority: .userInitiated) {
            var last: Result<ServerDeployment.VerificationReport, Error> = .failure(
                NSError(domain: "IPInformer.ServerVerification", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Verification was not run"]))
            for attempt in 0..<3 {
                last = Result { try ServerDeployment.verify(version: version, configSHA256: pending.configSHA256,
                                                            access: access, log: report) }
                if case .success(let check) = last, check.isInstalled { return last }
                if attempt < 2 { Thread.sleep(forTimeInterval: 1) }
            }
            return last
        }.value
        rootPassword = ""
        var finalLog: String
        switch verification {
        case .success(let check) where check.isInstalled:
            do {
                guard let data = client.data(using: .utf8),
                      let outbound = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let actualTag = outbound["tag"] as? String,
                      let actualType = outbound["type"] as? String else {
                    throw NSError(domain: "IPInformer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Клиентский JSON повреждён"])
                }
                var connection = ClientConnection(id: pending.id, name: connectionName, outboundTag: actualTag,
                                                  serverIPv4: serverHost, protocolName: actualType,
                                                  singBoxVersion: version)
                connection.serverArchitecture = check.architecture == "x86_64" ? "amd64"
                    : (["aarch64", "arm64"].contains(check.architecture) ? "arm64" : pending.architecture)
                connection.serverSSHPort = sshPort
                connection.installationVerified = true
                connection.installationCheckedAt = Date()
                try store.registerClientConnection(connection, outboundJSON: client,
                                                   serverConfiguration: server)
                PendingServerInstallationStore.remove(pending.id)
                pendingInstallation = nil
                status = "\(check.summary). Клиент \(connectionName) добавлен."
                finalLog = "\n\(check.summary). Клиент \(connectionName) добавлен.\n"
                if case .failure(let error) = result {
                    finalLog += "Первое SSH-соединение завершилось с ошибкой: \(error.localizedDescription)\n"
                }
            } catch {
                status = "Сервер проверен, но клиент не добавлен: \(error.localizedDescription)"
                finalLog = "\nОШИБКА добавления клиента: \(error.localizedDescription)\n"
            }
        case .success(let check):
            status = "Установка не подтверждена: \(check.summary). Скрипты сохранены в ожидающей установке."
            finalLog = "\n\(check.summary)\nСкрипты сохранены в разделе sing-box.\n"
            if case .failure(let error) = result { finalLog += "Ошибка установки: \(error.localizedDescription)\n" }
        case .failure(let error):
            status = "Установка не подтверждена: \(error.localizedDescription). Скрипты сохранены."
            finalLog = "\nПроверка VPS не удалась: \(error.localizedDescription)\nСкрипты сохранены в разделе sing-box.\n"
            if case .failure(let deployError) = result { finalLog += "Ошибка установки: \(deployError.localizedDescription)\n" }
        }
        DispatchQueue.main.async {
            logModel.append(finalLog)
            logModel.finish()
        }
    }
}
