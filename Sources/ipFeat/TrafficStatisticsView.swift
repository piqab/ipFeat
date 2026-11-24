import SwiftUI

private enum TrafficResetTarget {
    case route(String)
    case application(RoutedApplication)
}

struct TrafficStatisticsView: View {
    @ObservedObject var store: RoutingStore
    @ObservedObject private var statistics = TrafficStatistics.shared
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
                Text("Routes").font(.headline)
                let routeTags = Set(store.outboundTags).union(totals.routes.keys).sorted()
                ForEach(routeTags, id: \.self) { tag in
                    trafficRow(title: store.configuration.outboundDisplayName(for: tag), subtitle: tag,
                               bytes: totals.routes[tag] ?? TrafficBytes(),
                               rate: statistics.routeRates[tag] ?? TrafficBytes()) {
                        resetTarget = .route(tag)
                    }
                }
                Text("Programs").font(.headline)
                ForEach(apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { app in
                    trafficRow(title: app.name, subtitle: app.executablePath,
                               bytes: totals.applications[app.id] ?? TrafficBytes(),
                               rate: statistics.applicationRates[app.id] ?? TrafficBytes()) {
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

    private func trafficRow(title: String, subtitle: String, bytes: TrafficBytes,
                            rate: TrafficBytes, reset: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
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

    private func formatted(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
