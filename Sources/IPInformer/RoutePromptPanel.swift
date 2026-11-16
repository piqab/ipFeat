import AppKit
import SwiftUI

struct RoutePromptOption: Identifiable {
    let id = UUID()
    let label: String
    let route: DefaultRoute
}

enum RoutePromptDecision {
    case selected(DefaultRoute)
    case ordinaryPolicy
    case blocked
}

@MainActor
final class RoutePromptPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let onDecision: (RoutePromptDecision) -> Void
    private var finished = false

    init(title: String, detail: String, processPath: String, parentPath: String?,
         applicationName: String?, isUnknown: Bool, options: [RoutePromptOption],
         offset: Int, onDecision: @escaping (RoutePromptDecision) -> Void) {
        self.onDecision = onDecision
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
                        styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RoutePromptPanelView(
            title: title, detail: detail, processPath: processPath,
            parentPath: parentPath, applicationName: applicationName,
            isUnknown: isUnknown, options: options,
            onSelected: { [weak self] route in self?.finish(.selected(route)) },
            onOrdinary: { [weak self] in self?.finish(.ordinaryPolicy) }
        ))
        panel.center()
        let origin = panel.frame.origin
        let displacement = CGFloat(offset % 8) * 28
        panel.setFrameOrigin(NSPoint(x: origin.x + displacement, y: origin.y - displacement))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() { finish(.blocked) }

    func windowWillClose(_ notification: Notification) {
        finish(.blocked)
    }

    private func finish(_ decision: RoutePromptDecision) {
        guard !finished else { return }
        finished = true
        onDecision(decision)
        panel.close()
    }
}

private struct RoutePromptPanelView: View {
    let title: String
    let detail: String
    let processPath: String
    let parentPath: String?
    let applicationName: String?
    let isUnknown: Bool
    let options: [RoutePromptOption]
    let onSelected: (DefaultRoute) -> Void
    let onOrdinary: () -> Void

    @State private var selectedIndex = 0
    @State private var answer = "Click ? to ask the selected AI model what this process may be. Only the paths shown here are sent. AI never chooses the route."
    @State private var isAsking = false
    @State private var aiTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(detail).fixedSize(horizontal: false, vertical: true)
            Text(processPath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let parentPath, !parentPath.isEmpty {
                Text("Parent: \(parentPath)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Picker("Route", selection: $selectedIndex) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].label).tag(index)
                    }
                }
                Button {
                    askAI()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Ask AI what this process may be")
                .disabled(isAsking)
                if isAsking { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 112)
            .padding(8)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button(isUnknown ? "Use default route" : "Use application route") { onOrdinary() }
                Button(isUnknown ? "Use for this run" : "Remember route") {
                    guard options.indices.contains(selectedIndex) else { return }
                    onSelected(options[selectedIndex].route)
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("If no route is chosen within 20 seconds, the first connection is blocked. This window stays open; your choice applies to later connections.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 540)
        .onDisappear { aiTask?.cancel() }
    }

    private func askAI() {
        guard let profile = ProcessAISettings.shared.selectedProfile else {
            answer = "Configure and select a model in Settings → AI."
            return
        }
        isAsking = true
        answer = "Asking \(profile.name)…"
        aiTask = Task { @MainActor in
            do {
                let result = try await ProcessAIClient.explain(
                    processPath: processPath, parentPath: parentPath,
                    applicationName: applicationName, profile: profile
                )
                if !Task.isCancelled { answer = result }
            } catch {
                if !Task.isCancelled { answer = "AI request failed: \(error.localizedDescription)" }
            }
            isAsking = false
        }
    }
}
