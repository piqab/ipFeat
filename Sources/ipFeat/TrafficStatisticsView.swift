import SwiftUI

private enum TrafficResetTarget {
    case route(String)
    case application(RoutedApplication)
}

private enum TrafficSortOption: String, CaseIterable, Identifiable {
    case nameAscending, nameDescending
    case currentTotal, currentDownload, currentUpload
    case periodTotal, periodDownload, periodUpload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAscending: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        case .currentTotal: return "Current traffic ↓+↑"
        case .currentDownload: return "Current download ↓"
        case .currentUpload: return "Current upload ↑"
        case .periodTotal: return "Period traffic ↓+↑"
        case .periodDownload: return "Period download ↓"
        case .periodUpload: return "Period upload ↑"
        }
    }

    func value(total: TrafficBytes, rate: TrafficBytes) -> Int64 {
        let bytes = rawValue.hasPrefix("current") ? rate : total
        switch self {
        case .currentTotal, .periodTotal:
            let (sum, overflow) = bytes.download.addingReportingOverflow(bytes.upload)
            return overflow ? Int64.max : sum
        case .currentDownload, .periodDownload: return bytes.download
        case .currentUpload, .periodUpload: return bytes.upload
        case .nameAscending, .nameDescending: return 0
        }
    }
}

struct TrafficStatisticsView: View {
    @ObservedObject var store: RoutingStore
    @ObservedObject private var statistics = TrafficStatistics.shared
    @AppStorage("traffic.routesSort") private var routeSortRaw = TrafficSortOption.nameAscending.rawValue
    @AppStorage("traffic.programsSort") private var programSortRaw = TrafficSortOption.nameAscending.rawValue
    @State private var period: TrafficPeriod = .today
    @State private var resetTarget: TrafficResetTarget?
    @State private var actionError: String?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let apps = store.configuration.applications
        let totals = statistics.totals(applications: apps, period: period,
                                      today: TrafficStatistics.todayString())
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Traffic").font(.title2.bold())
                Text("IPv4 traffic observed by the patched sing-box service. Upload and download are counted on the actual route. Local connections that bypass sing-box are not counted.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Period", selection: $period) {
                    ForEach(TrafficPeriod.allCases) { choice in
                        Text(LocalizedStringKey(choice.title)).tag(choice)
                    }
                }.pickerStyle(.segmented)
                if statistics.live == nil {
                    Text("No traffic data yet. Update the ipFeat sing-box patch and start the network service.")
                        .foregroundStyle(.secondary)
                }
                if let message = actionError ?? statistics.error {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Text("Routes").font(.headline)
                    Spacer()
                    sortPicker("Sort routes", selection: $routeSortRaw)
                }
                let routeTags = sorted(Array(Set(store.outboundTags).union(totals.routes.keys)),
                                       by: TrafficSortOption(rawValue: routeSortRaw) ?? .nameAscending,
                                       name: { store.configuration.outboundDisplayName(for: $0) },
                                       tieBreaker: { $0 },
                                       total: { totals.routes[$0] ?? TrafficBytes() },
                                       rate: { statistics.routeRates[$0] ?? TrafficBytes() })
                ForEach(routeTags, id: \.self) { tag in
                    trafficRow(title: store.configuration.outboundDisplayName(for: tag), subtitle: tag,
                               bytes: totals.routes[tag] ?? TrafficBytes(),
                               rate: statistics.routeRates[tag] ?? TrafficBytes()) {
                        resetTarget = .route(tag)
                    }
                }
                HStack {
                    Text("Programs").font(.headline)
                    Spacer()
                    sortPicker("Sort programs", selection: $programSortRaw)
                }
                let sortedApps = sorted(apps,
                                        by: TrafficSortOption(rawValue: programSortRaw) ?? .nameAscending,
                                        name: { $0.name }, tieBreaker: { $0.executablePath },
                                        total: { totals.applications[$0.id] ?? TrafficBytes() },
                                        rate: { statistics.applicationRates[$0.id] ?? TrafficBytes() })
                ForEach(sortedApps) { app in
                    trafficRow(title: app.name, subtitle: app.executablePath,
                               bytes: totals.applications[app.id] ?? TrafficBytes(),
                               rate: statistics.applicationRates[app.id] ?? TrafficBytes(), application: app) {
                        resetTarget = .application(app)
                    }
                }
                Text("A child process is counted under the nearest registered parent application. Connections without a verified owner remain in route totals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { statistics.refresh(applications: apps) }
        .onReceive(timer) { _ in statistics.refresh(applications: store.configuration.applications) }
        .confirmationDialog("Reset traffic counter?", isPresented: Binding(
            get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }
        )) {
            Button("Reset counter", role: .destructive) {
                do {
                    switch resetTarget {
                    case .route(let tag):
                        try statistics.resetRoute(tag, applications: store.configuration.applications)
                    case .application(let app):
                        try statistics.resetApplication(app, applications: store.configuration.applications)
                    case nil: break
                    }
                    actionError = nil
                } catch { actionError = error.localizedDescription }
                resetTarget = nil
            }
        }
    }

    private func sortPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(LocalizedStringKey(title), selection: selection) {
            ForEach(TrafficSortOption.allCases) { option in
                Text(LocalizedStringKey(option.title)).tag(option.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 245)
    }

    private func sorted<Item>(_ items: [Item], by option: TrafficSortOption,
                              name: (Item) -> String, tieBreaker: (Item) -> String,
                              total: (Item) -> TrafficBytes, rate: (Item) -> TrafficBytes) -> [Item] {
        items.sorted { left, right in
            if option != .nameAscending && option != .nameDescending {
                let leftValue = option.value(total: total(left), rate: rate(left))
                let rightValue = option.value(total: total(right), rate: rate(right))
                if leftValue != rightValue { return leftValue > rightValue }
            }
            let comparison = name(left).localizedStandardCompare(name(right))
            if comparison != .orderedSame {
                return option == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
            return tieBreaker(left) < tieBreaker(right)
        }
    }

    private func trafficRow(title: String, subtitle: String, bytes: TrafficBytes,
                            rate: TrafficBytes, application: RoutedApplication? = nil,
                            reset: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let application {
                Menu {
                    Button(AppLanguage.localized("Общий маршрут")) {
                        setApplicationRoute(application, profileID: nil)
                    }
                    ForEach(store.configuration.profiles) { profile in
                        Button(profile.displayName) {
                            setApplicationRoute(application, profileID: profile.id)
                        }
                    }
                } label: {
                    Text(applicationRouteLabel(application))
                        .lineLimit(1)
                        .font(.caption)
                }
                .frame(maxWidth: 190)
                .help(AppLanguage.localized(application.groupID == nil
                    ? "Choose a personal route for this program."
                    : "Choosing a personal route moves this program out of its group."))
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text("↑ \(formatted(bytes.upload))  ↓ \(formatted(bytes.download))")
                    .font(.caption.monospacedDigit())
                Text("↑ \(formatted(rate.upload))/s  ↓ \(formatted(rate.download))/s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Reset", action: reset).controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func applicationRouteLabel(_ application: RoutedApplication) -> String {
        let group = store.configuration.groups.first(where: { $0.id == application.groupID })
        let profileID = SingBoxConfigurationGenerator.effectiveProfileID(for: application,
                                                                          configuration: store.configuration)
        let title = profileID.flatMap { id in
            store.configuration.profiles.first(where: { $0.id == id })?.displayName
        } ?? AppLanguage.localized("Общий маршрут")
        return group.map { "\($0.name) · \(title)" } ?? title
    }

    private func setApplicationRoute(_ application: RoutedApplication, profileID: UUID?) {
        guard var updated = store.configuration.applications.first(where: { $0.id == application.id }) else { return }
        updated.groupID = nil
        updated.profileID = profileID
        store.updateApplication(updated)
    }

    private func formatted(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
