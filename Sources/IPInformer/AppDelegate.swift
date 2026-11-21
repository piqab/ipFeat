import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let routingStore = RoutingStore()
    private lazy var childRoutePromptServer = ChildRoutePromptServer(store: routingStore)
    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        createStatusItem()
        routingStore.startNetworkTopologyMonitoring()
        childRoutePromptServer.start()
        let hasEngine = [
            "/Library/Application Support/IPInformer/engines/current",
            "/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"
        ].contains { FileManager.default.isExecutableFile(atPath: $0) }
        if !hasEngine { showSettings(initialTab: 3) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        routingStore.stopNetworkTopologyMonitoring()
        childRoutePromptServer.stop()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "IP Informer"
        item.button?.target = self
        item.button?.action = #selector(toggleStatusPopover)
        statusPopover.behavior = .transient
        statusItem = item
    }

    private func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "network", accessibilityDescription: "IP Informer")
        }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func toggleStatusPopover() {
        guard let button = statusItem?.button else { return }
        if statusPopover.isShown {
            statusPopover.performClose(nil)
            return
        }
        let visibleApps = routingStore.configuration.applications.filter {
            $0.bundleIdentifier != RoutingStore.selfBundleIdentifier
        }
        let groupIDs = Set(routingStore.configuration.groups.map(\.id))
        let nonEmptyGroups = routingStore.configuration.groups.filter { group in
            visibleApps.contains(where: { $0.groupID == group.id })
        }.count
        let hasUngrouped = visibleApps.contains { application in
            guard let id = application.groupID else { return true }
            return !groupIDs.contains(id)
        }
        let rowCount = nonEmptyGroups + (hasUngrouped ? 1 : 0)
        let content = MenuBarPopoverView(
            store: routingStore,
            openSettings: { [weak self] in self?.openSettings() },
            addApplications: { [weak self] groupID in self?.chooseApplications(toGroup: groupID) },
            quit: { NSApp.terminate(nil) },
            close: { [weak self] in self?.statusPopover.performClose(nil) }
        )
        statusPopover.contentViewController = NSHostingController(rootView: content.environment(\.locale, AppLanguage.locale))
        statusPopover.contentSize = NSSize(width: 340, height: MenuBarPopoverView.preferredHeight(rowCount: rowCount))
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func openSettings() {
        showSettings(initialTab: 0)
    }

    private func chooseApplications(toGroup groupID: UUID?) {
        statusPopover.performClose(nil)
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("Выберите программы")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let errors = routingStore.addApplications(at: panel.urls, toGroup: groupID)
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = AppLanguage.localized("Не удалось добавить некоторые программы")
            alert.informativeText = errors.joined(separator: "\n")
            alert.runModal()
        }
    }

    private func showSettings(initialTab: Int) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = SettingsView(routingStore: routingStore, initialTab: initialTab)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = AppLanguage.localized("Настройки IP Informer")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(initialTab: 0)
        return true
    }
}
