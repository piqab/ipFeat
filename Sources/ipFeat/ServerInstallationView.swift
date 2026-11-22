import AppKit
import SwiftUI

struct ServerInstallationView: View {
    @ObservedObject var store: RoutingStore
    let connection: ClientConnection
    @Environment(\.dismiss) private var dismiss
    @State private var architecture: String
    @State private var sshPort: String
    @State private var authentication = "password"
    @State private var sshUser = "root"
    @State private var rootPassword = ""
    @State private var identityFile = ""
    @State private var checking = false
    @State private var legacyInstalled = false
    @State private var message = ""
    @State private var details = ""

    init(store: RoutingStore, connection: ClientConnection) {
        self.store = store
        self.connection = connection
        _architecture = State(initialValue: connection.serverArchitecture ?? "amd64")
        _sshPort = State(initialValue: String(connection.serverSSHPort ?? 22))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server installation and verification").font(.title2.weight(.semibold))
            Text("\(connection.name) · \(connection.serverIPv4) · sing-box \(connection.singBoxVersion)")
                .font(.caption.monospaced())
            Picker("VPS architecture", selection: $architecture) {
                Text("x86_64 / amd64").tag("amd64")
                Text("aarch64 / arm64").tag("arm64")
            }.frame(maxWidth: 280)
            TextField("SSH port", text: $sshPort).frame(width: 130)
            HStack {
                Button("Copy VPS installation script") { copyScript(onHost: false) }
                Button("Copy host installation script") { copyScript(onHost: true) }
            }
            Text("Both scripts contain server credentials. The host script is self-contained and downloads the Linux archive before connecting to the VPS.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("SSH authentication", selection: $authentication) {
                Text("Root password").tag("password")
                Text("SSH key").tag("key")
            }.pickerStyle(.segmented).frame(width: 280)
            if authentication == "password" {
                SecureField("Root password", text: $rootPassword).frame(maxWidth: 330)
            } else {
                HStack {
                    TextField("SSH user", text: $sshUser).frame(width: 140)
                    TextField("SSH key path", text: $identityFile)
                    Button("Choose…") { chooseKey() }
                }
            }
            Button("Check installation") { checkInstallation() }
                .disabled(checking || (authentication == "password" && rootPassword.isEmpty)
                          || (authentication == "key" && identityFile.isEmpty))
            if legacyInstalled {
                Button("Migrate previous service to ipFeat") { migrateLegacyService() }
                    .disabled(checking || (authentication == "password" && rootPassword.isEmpty)
                              || (authentication == "key" && identityFile.isEmpty))
            }
            if checking { ProgressView("Checking VPS…") }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            if !details.isEmpty {
                ScrollView {
                    Text(details).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)
            }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding(20)
        .frame(width: 720)
    }

    private func installationRecord() throws -> PendingServerInstallation {
        guard let serverJSON = ServerSecretStore.load(id: connection.id) else {
            throw NSError(domain: "ipFeat.ServerInstallation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Saved server JSON was not found in Keychain"])
        }
        guard let port = Int(sshPort), (1...65535).contains(port) else {
            throw NSError(domain: "ipFeat.ServerInstallation", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SSH port must be between 1 and 65535"])
        }
        return PendingServerInstallation(id: connection.id, name: connection.name,
            serverIPv4: connection.serverIPv4, sshPort: port, architecture: architecture,
            version: connection.singBoxVersion, protocolName: connection.protocolName,
            outboundTag: connection.outboundTag, clientJSON: connection.outboundJSON ?? "",
            serverJSON: serverJSON, createdAt: connection.createdAt)
    }

    private func copyScript(onHost: Bool) {
        do {
            let record = try installationRecord()
            let script = try onHost ? record.hostScript() : record.serverScript()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(script, forType: .string)
            message = AppLanguage.localized(onHost ? "Standalone host installer copied." : "VPS installer copied.")
        } catch { message = error.localizedDescription }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityFile = url.path
    }

    private func checkInstallation() {
        let record: PendingServerInstallation
        do { record = try installationRecord() }
        catch { message = error.localizedDescription; return }
        let access = ServerSSHSettings(host: connection.serverIPv4,
            user: authentication == "password" ? "root" : sshUser,
            port: record.sshPort,
            authentication: authentication == "password" ? .rootPassword(rootPassword) : .key(identityFile))
        checking = true
        message = ""
        details = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ServerDeployment.verify(version: record.version,
                                                     configSHA256: record.configSHA256, access: access) }
            }.value
            rootPassword = ""
            checking = false
            switch result {
            case .success(let report):
                let normalizedArchitecture: String? = report.architecture == "x86_64" ? "amd64"
                    : (["aarch64", "arm64"].contains(report.architecture) ? "arm64" : nil)
                store.updateServerInstallation(connection.id, verified: report.isInstalled,
                                               architecture: normalizedArchitecture, sshPort: record.sshPort)
                architecture = normalizedArchitecture ?? architecture
                message = report.summary
                legacyInstalled = report.isInstalled && report.legacyService
                details = report.output
            case .failure(let error):
                store.updateServerInstallation(connection.id, verified: false,
                                               architecture: architecture, sshPort: record.sshPort)
                message = String(format: AppLanguage.localized("Could not verify VPS: %@"), error.localizedDescription)
            }
        }
    }

    private func migrateLegacyService() {
        let record: PendingServerInstallation
        do { record = try installationRecord() }
        catch { message = error.localizedDescription; return }
        let access = ServerSSHSettings(host: connection.serverIPv4,
            user: authentication == "password" ? "root" : sshUser, port: record.sshPort,
            authentication: authentication == "password" ? .rootPassword(rootPassword) : .key(identityFile))
        checking = true
        message = ""
        details = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let migrationLog = try ServerDeployment.migrateLegacy(version: record.version,
                        configSHA256: record.configSHA256, access: access)
                    let report = try ServerDeployment.verify(version: record.version,
                        configSHA256: record.configSHA256, access: access)
                    return (migrationLog, report)
                }
            }.value
            rootPassword = ""
            checking = false
            switch result {
            case .success(let (migrationLog, report)):
                store.updateServerInstallation(connection.id, verified: report.isInstalled,
                    architecture: architecture, sshPort: record.sshPort)
                legacyInstalled = report.isInstalled && report.legacyService
                message = report.summary
                details = migrationLog + "\n" + report.output
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }
}
