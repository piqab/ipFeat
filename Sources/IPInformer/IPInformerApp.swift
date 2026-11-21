import SwiftUI

@main
struct IPInformerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { AppLanguage.applyAtLaunch() }

    var body: some Scene {
        Settings {
            SettingsView(routingStore: appDelegate.routingStore)
        }
    }
}
