import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let widgetsVisibleKey = "widgetsVisible"

    let monitor = IPMonitor()
    let routingStore = RoutingStore()

    private var panelsByScreen: [String: NSPanel] = [:]
    private var statusItem: NSStatusItem?
    private var addressMenuItem: NSMenuItem?
    private var toggleWidgetItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var widgetsVisible: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppDelegate.widgetsVisibleKey) != nil else { return true }
        return defaults.bool(forKey: AppDelegate.widgetsVisibleKey)
    }()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        synchronizePanels()
        createStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        monitor.onAddressChange = { [weak self] oldAddress, newAddress in
            self?.announceChange(from: oldAddress, to: newAddress)
        }
        monitor.$ipv4
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        monitor.start()
        routingStore.startRouteMonitoring { [weak monitor = monitor] in
            monitor?.sources ?? []
        }
        let hasEngine = [
            "/Library/Application Support/IPInformer/engines/current",
            "/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"
        ].contains { FileManager.default.isExecutableFile(atPath: $0) }
        if !hasEngine { showSettings(initialTab: 3) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        monitor.stop()
        routingStore.stopRouteMonitoring()
    }

    private func makePanel(for screen: NSScreen, identifier: String) -> NSPanel {
        let content = WidgetView(monitor: monitor)
        let hostingController = NSHostingController(rootView: content)
        let size = NSSize(width: 146, height: 28)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self
        panel.setContentSize(size)

        let visible = screen.visibleFrame
        let savedOffset = UserDefaults.standard.string(forKey: "widgetOffset.\(identifier)")
            .map(NSPointFromString)
        let xOffset = min(max(savedOffset?.x ?? (visible.width - size.width - 24), 0), max(visible.width - size.width, 0))
        let topOffset = min(max(savedOffset?.y ?? 24, 0), max(visible.height - size.height, 0))
        panel.setFrameOrigin(NSPoint(
            x: visible.minX + xOffset,
            y: visible.maxY - size.height - topOffset
        ))

        if widgetsVisible {
            panel.orderFrontRegardless()
        }
        return panel
    }

    private func synchronizePanels() {
        let currentScreens = Dictionary(uniqueKeysWithValues: NSScreen.screens.map {
            (screenIdentifier($0), $0)
        })

        for identifier in Array(panelsByScreen.keys) where currentScreens[identifier] == nil {
            panelsByScreen.removeValue(forKey: identifier)?.close()
        }

        for (identifier, screen) in currentScreens where panelsByScreen[identifier] == nil {
            panelsByScreen[identifier] = makePanel(for: screen, identifier: identifier)
        }
    }

    private func screenIdentifier(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "IP Informer")

        let menu = NSMenu()
        let addressItem = NSMenuItem(title: "IP Informer", action: nil, keyEquivalent: "")
        addressItem.isEnabled = false
        menu.addItem(addressItem)
        addressMenuItem = addressItem
        menu.addItem(.separator())

        let checkItem = NSMenuItem(title: "Проверить сейчас", action: #selector(checkNow), keyEquivalent: "r")
        checkItem.target = self
        menu.addItem(checkItem)

        let toggleTitle = widgetsVisible ? "Скрыть виджеты" : "Показать виджеты"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleWidget), keyEquivalent: "h")
        toggleItem.target = self
        menu.addItem(toggleItem)
        toggleWidgetItem = toggleItem

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить IP Informer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    @objc private func checkNow() {
        monitor.checkNow()
    }

    @objc private func toggleWidget() {
        widgetsVisible.toggle()
        UserDefaults.standard.set(widgetsVisible, forKey: Self.widgetsVisibleKey)
        for panel in panelsByScreen.values {
            if widgetsVisible {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        }
        toggleWidgetItem?.title = widgetsVisible ? "Скрыть виджеты" : "Показать виджеты"
        updateStatusItem()
    }

    @objc private func screenParametersDidChange() {
        synchronizePanels()
    }

    @objc private func openSettings() {
        showSettings(initialTab: 0)
    }

    private func showSettings(initialTab: Int) {
        if let settingsWindow {
            NSApp.setActivationPolicy(.regular)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SettingsView(monitor: monitor, routingStore: routingStore, initialTab: initialTab)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = "Настройки IP Informer"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()
        window.delegate = self
        settingsWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let entry = panelsByScreen.first(where: { $0.value === panel }),
              let assignedScreen = NSScreen.screens.first(where: { screenIdentifier($0) == entry.key }) else {
            return
        }

        let visible = assignedScreen.visibleFrame
        let offset = NSPoint(
            x: panel.frame.minX - visible.minX,
            y: visible.maxY - panel.frame.maxY
        )
        UserDefaults.standard.set(NSStringFromPoint(offset), forKey: "widgetOffset.\(entry.key)")
    }

    private func announceChange(from oldAddress: String, to newAddress: String) {
        NSSound(named: "Ping")?.play()
        monitor.flash()
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        addressMenuItem?.title = "IPv4: \(monitor.ipv4)"
        button.toolTip = "IP Informer — \(monitor.ipv4)"

        if widgetsVisible {
            statusItem.length = NSStatusItem.squareLength
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "IP Informer")
            button.title = ""
        } else {
            let firstOctet = monitor.ipv4.split(separator: ".").first.map(String.init)
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.title = firstOctet ?? "IP"
        }
    }
}
