import SwiftUI

struct SettingsView: View {
    @ObservedObject var routingStore: RoutingStore
    @State private var selectedTab: Int
    @AppStorage(AppLanguage.preferenceKey) private var preferredAppLanguage = AppLanguage.system.rawValue

    init(routingStore: RoutingStore, initialTab: Int = 0) {
        self.routingStore = routingStore
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            RoutingSettingsView(store: routingStore, section: .programs)
                .tabItem { Label("Программы", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(0)
            RoutingSettingsView(store: routingStore, section: .profiles)
                .tabItem { Label("Профили", systemImage: "slider.horizontal.3") }
                .tag(1)
            SingBoxSettingsView(store: routingStore)
                .tabItem { Label("sing-box", systemImage: "network.badge.shield.half.filled") }
                .tag(2)
            ProcessAISettingsView()
                .tabItem { Label("AI", systemImage: "questionmark.bubble") }
                .tag(3)
        }
        .frame(width: 820, height: 620)
        .environment(\.locale, preferredAppLanguage == AppLanguage.system.rawValue
                     ? .autoupdatingCurrent : Locale(identifier: preferredAppLanguage))
    }
}
