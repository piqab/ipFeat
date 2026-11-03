import AppKit
import SwiftUI

struct ApplicationMenuIconButton: NSViewRepresentable {
    let application: RoutedApplication
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        var iconPath: String?

        @objc func activate(_ sender: NSButton) {
            action()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        if context.coordinator.iconPath != application.bundlePath {
            let icon = NSWorkspace.shared.icon(forFile: application.bundlePath).copy() as? NSImage
            icon?.size = NSSize(width: 30, height: 30)
            button.image = icon
            context.coordinator.iconPath = application.bundlePath
        }
        button.toolTip = application.name
        button.setAccessibilityLabel(application.name)
        button.isEnabled = application.enabled
        button.alphaValue = application.enabled ? 1 : 0.4
    }
}
