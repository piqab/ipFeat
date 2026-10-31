import AppKit
import SwiftUI

@MainActor
final class ServerDeploymentLogModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var isRunning = false

    func reset() {
        text = ""
        isRunning = true
    }

    func append(_ chunk: String) {
        text += chunk
        if text.count > 200_000 {
            text = "[Начало лога сокращено]\n" + String(text.suffix(150_000))
        }
    }

    func finish() { isRunning = false }
}

struct ServerDeploymentLogView: View {
    @ObservedObject var model: ServerDeploymentLogModel
    var title = "Установка sing-box на VPS"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
            }
            Text("Команды и ответы сервера. Пароль SSH и сам JSON в команды лога не включаются.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { reader in
                ScrollView {
                    Text(model.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log-end")
                }
                .onChange(of: model.text) { _ in reader.scrollTo("log-end", anchor: .bottom) }
            }
            .frame(minHeight: 340)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)) }
            HStack {
                Button("Скопировать лог") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 800, height: 500)
    }
}
