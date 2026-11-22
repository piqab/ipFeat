import AppKit
import SwiftUI

private final class ApplicationIconButtonView: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
        super.mouseExited(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onHoverChange?(false)
        if let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

struct ApplicationMenuIconButton: NSViewRepresentable {
    let application: RoutedApplication
    let groups: [RoutingGroup]
    let action: () -> Void
    let onMove: (UUID?) -> Void
    let onDelete: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        var onMove: (UUID?) -> Void = { _ in }
        var onDelete: () -> Void = {}
        var canLaunch = true
        var iconPath: String?
        var applicationName = ""
        var groups: [RoutingGroup] = []
        var currentGroupID: UUID?
        private var tooltipWorkItem: DispatchWorkItem?
        private var tooltipPopover: NSPopover?

        @objc func activate(_ sender: NSButton) {
            guard canLaunch else { return }
            action()
        }

        func setHovered(_ hovered: Bool, button: NSButton) {
            tooltipWorkItem?.cancel()
            tooltipWorkItem = nil
            tooltipPopover?.close()
            tooltipPopover = nil
            guard hovered else { return }
            let workItem = DispatchWorkItem { [weak self, weak button] in
                guard let self, let button, button.window != nil else { return }
                let tooltip = NSPopover()
                tooltip.animates = false
                tooltip.behavior = .semitransient
                let label = Text(self.applicationName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                tooltip.contentViewController = NSHostingController(rootView: label)
                let font = NSFont.systemFont(ofSize: 12)
                let textWidth = (self.applicationName as NSString).size(withAttributes: [.font: font]).width
                tooltip.contentSize = NSSize(width: min(max(textWidth + 20, 60), 280), height: 28)
                tooltip.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
                self.tooltipPopover = tooltip
            }
            tooltipWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            let moveItem = NSMenuItem(title: "Перенести", action: nil, keyEquivalent: "")
            let destinations = NSMenu(title: "Перенести")
            if currentGroupID != nil {
                let item = NSMenuItem(title: "Без группы", action: #selector(move(_:)), keyEquivalent: "")
                item.tag = 0
                item.target = self
                item.representedObject = self
                destinations.addItem(item)
            }
            for (index, group) in groups.enumerated() where group.id != currentGroupID {
                let item = NSMenuItem(title: group.name, action: #selector(move(_:)), keyEquivalent: "")
                item.tag = index + 1
                item.target = self
                item.representedObject = self
                destinations.addItem(item)
            }
            moveItem.submenu = destinations
            moveItem.isEnabled = !destinations.items.isEmpty
            menu.addItem(moveItem)
            menu.addItem(.separator())
            let deleteItem = NSMenuItem(title: "Удалить из ipFeat", action: #selector(delete(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = self
            menu.addItem(deleteItem)
            return menu
        }

        @objc private func move(_ sender: NSMenuItem) {
            if sender.tag == 0 {
                onMove(nil)
            } else if groups.indices.contains(sender.tag - 1) {
                onMove(groups[sender.tag - 1].id)
            }
        }

        @objc private func delete(_ sender: NSMenuItem) {
            onDelete()
        }

        deinit {
            tooltipWorkItem?.cancel()
            tooltipPopover?.close()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = ApplicationIconButtonView()
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        button.onHoverChange = { [weak coordinator = context.coordinator, weak button] hovered in
            guard let button else { return }
            coordinator?.setHovered(hovered, button: button)
        }
        button.contextMenuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeContextMenu() ?? NSMenu()
        }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.onMove = onMove
        context.coordinator.onDelete = onDelete
        context.coordinator.canLaunch = application.enabled
        context.coordinator.applicationName = application.name
        context.coordinator.groups = groups
        context.coordinator.currentGroupID = application.groupID
        if context.coordinator.iconPath != application.bundlePath {
            let icon = NSWorkspace.shared.icon(forFile: application.bundlePath).copy() as? NSImage
            icon?.size = NSSize(width: 30, height: 30)
            button.image = icon
            context.coordinator.iconPath = application.bundlePath
        }
        button.setAccessibilityLabel(application.name)
        button.alphaValue = application.enabled ? 1 : 0.4
    }
}
