import ServiceManagement
import SwiftUI

struct AppPreferencesSection: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @AppStorage(AppLanguage.preferenceKey) private var preferredAppLanguage = AppLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App settings").font(.headline)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { updateLaunchAtLogin($0) }
            HStack {
                Picker("Interface language", selection: $preferredAppLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .frame(width: 300)
                .onChange(of: preferredAppLanguage) { AppLanguage.set($0) }
                Text("Restart ipFeat to apply the language everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.red)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ipFeatConfigurationRestored)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = String(format: AppLanguage.localized("Could not change launch at login: %@"),
                                 error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
