import SwiftUI

@main
struct ipFeatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LegacyDataMigration.run()
        AppLanguage.applyAtLaunch()
    }

    var body: some Scene {
        Settings {
            SettingsView(routingStore: appDelegate.routingStore)
        }
    }
}
