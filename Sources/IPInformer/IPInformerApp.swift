import SwiftUI

@main
struct IPInformerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(monitor: appDelegate.monitor, routingStore: appDelegate.routingStore)
        }
    }
}
