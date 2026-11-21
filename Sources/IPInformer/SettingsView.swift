import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var routingStore: RoutingStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var selectedTab: Int
    @AppStorage(AppLanguage.preferenceKey) private var preferredAppLanguage = AppLanguage.system.rawValue

    init(routingStore: RoutingStore, initialTab: Int = 0) {
        self.routingStore = routingStore
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)
            RoutingSettingsView(store: routingStore, section: .programs)
                .tabItem { Label("Программы", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(1)
            RoutingSettingsView(store: routingStore, section: .profiles)
                .tabItem { Label("Профили", systemImage: "slider.horizontal.3") }
                .tag(2)
            SingBoxSettingsView(store: routingStore)
                .tabItem { Label("sing-box", systemImage: "network.badge.shield.half.filled") }
                .tag(3)
            ProcessAISettingsView()
                .tabItem { Label("AI", systemImage: "questionmark.bubble") }
                .tag(4)
        }
        .frame(width: 820, height: 620)
        .environment(\.locale, preferredAppLanguage == AppLanguage.system.rawValue
                     ? .autoupdatingCurrent : Locale(identifier: preferredAppLanguage))
        .onReceive(NotificationCenter.default.publisher(for: .ipInformerConfigurationRestored)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("General settings").font(.headline)
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
                Text("Restart IP Informer to apply the language everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
