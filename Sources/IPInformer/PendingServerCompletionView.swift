import AppKit
import SwiftUI

struct PendingServerCompletionView: View {
    @ObservedObject var store: RoutingStore
    let pending: PendingServerInstallation
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Complete manual VPS installation").font(.title2.weight(.semibold))
            Text("\(pending.name) · \(pending.serverIPv4) · sing-box \(pending.version) · \(pending.architecture)")
                .font(.caption.monospaced())
            Text("Run the server script as root on the VPS, or the host script from another Mac/Linux computer. Copy the IPINFORMER_INSTALL_OK line printed after the service becomes active and enabled at boot.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy server installation script") { copyScript() }
                Button("Copy host installation script") { copyHostScript() }
                Button("Export installation package…") { exportPackage() }
            }
            TextField("Paste IPINFORMER_INSTALL_OK line", text: $result)
                .textFieldStyle(.roundedBorder)
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Add client") { complete() }
                    .buttonStyle(.borderedProminent).disabled(result.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func copyScript() {
        do {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(try pending.serverScript(), forType: .string)
            message = "Server script copied. It contains server credentials."
        } catch { message = error.localizedDescription }
    }

    private func copyHostScript() {
        do {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(try pending.hostScript(), forType: .string)
            message = "Standalone host script copied. It contains server credentials."
        } catch { message = error.localizedDescription }
    }

    private func exportPackage() {
        do {
            let panel = NSOpenPanel()
            panel.title = "Choose a private folder for the installation package"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let parent = panel.url else { return }
            let destination = parent.appendingPathComponent("IPInformer-Server-\(pending.id.uuidString.prefix(8))")
            try pending.writePackage(to: destination)
            message = "Installation package saved: \(destination.path)"
        } catch { message = error.localizedDescription }
    }

    private func complete() {
        do {
            try store.completePendingServerInstallation(pending, result: result)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
