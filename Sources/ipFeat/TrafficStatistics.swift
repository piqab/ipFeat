import Foundation

struct TrafficBytes: Codable, Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(upload: lhs.upload + rhs.upload, download: lhs.download + rhs.download)
    }

    func after(_ baseline: Self) -> Self {
        Self(upload: max(0, upload - baseline.upload), download: max(0, download - baseline.download))
    }
}

struct TrafficEntry: Codable, Equatable {
    var day: String
    var route: String
    var paths: [String]
    var upload: Int64
    var download: Int64
    var bytes: TrafficBytes { TrafficBytes(upload: upload, download: download) }
}

struct TrafficDocument: Codable, Equatable {
    var version: Int
    var id: String
    var updatedAt: String
    var entries: [TrafficEntry]
}

struct TrafficSnapshot: Codable, Equatable {
    var sources: [TrafficDocument] = []
    var routeResets: [String: [String: TrafficBytes]] = [:]
    var applicationResets: [String: [String: TrafficBytes]] = [:]
    var applicationPaths: [String: [String]] = [:]

    func valid() -> Bool {
        Set(sources.map(\.id)).count == sources.count && sources.allSatisfy { document in
            document.version == 1 && !document.id.isEmpty && document.entries.count <= 100_000 &&
            document.entries.allSatisfy {
                !$0.day.isEmpty && !$0.route.isEmpty && $0.upload >= 0 && $0.download >= 0
            }
        } && applicationPaths.values.allSatisfy { $0.count <= 32 && $0.allSatisfy { !$0.isEmpty } } &&
        [routeResets, applicationResets].allSatisfy { groups in
            groups.values.allSatisfy { days in
                days.values.allSatisfy { $0.upload >= 0 && $0.download >= 0 }
            }
        }
    }
}

enum TrafficPeriod: String, CaseIterable, Identifiable {
    case today, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .month: return "This month"
        case .all: return "All time"
        }
    }
    func includes(_ day: String, today: String) -> Bool {
        switch self {
        case .today: return day == today
        case .month: return day.hasPrefix(String(today.prefix(7)))
        case .all: return true
        }
    }
}

enum TrafficStatisticsError: LocalizedError {
    case invalidData
    var errorDescription: String? {
        AppLanguage.localized("Traffic statistics are damaged or use an unsupported format.")
    }
}

@MainActor
final class TrafficStatistics: ObservableObject {
    static let shared = TrafficStatistics()
    @Published private(set) var live: TrafficDocument?
    @Published private(set) var state = TrafficSnapshot()
    @Published private(set) var error: String?
    @Published private(set) var routeRates: [String: TrafficBytes] = [:]
    @Published private(set) var applicationRates: [UUID: TrafficBytes] = [:]

    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ipFeat", isDirectory: true)
    private static let liveURL = directory.appendingPathComponent("traffic-stats.json")
    private static let stateURL = directory.appendingPathComponent("traffic-history.json")
    private var lastRefresh = Date()
    private var lastLive: TrafficDocument?
    private var stateIsValid = true

    private init() {
        if FileManager.default.fileExists(atPath: Self.stateURL.path) {
            do {
                let loaded = try JSONDecoder().decode(TrafficSnapshot.self, from: Data(contentsOf: Self.stateURL))
                guard loaded.valid() else { throw TrafficStatisticsError.invalidData }
                state = loaded
            } catch {
                stateIsValid = false
                self.error = error.localizedDescription
            }
        }
        refresh(applications: [])
    }

    func refresh(applications: [RoutedApplication]) {
        do {
            guard FileManager.default.fileExists(atPath: Self.liveURL.path) else {
                live = nil
                routeRates = [:]
                applicationRates = [:]
                return
            }
            let current = try JSONDecoder().decode(TrafficDocument.self, from: Data(contentsOf: Self.liveURL))
            guard TrafficSnapshot(sources: [current]).valid() else { throw TrafficStatisticsError.invalidData }
            let now = Date()
            let seconds = now.timeIntervalSince(lastRefresh)
            if let lastLive, lastLive.id == current.id, seconds > 0 {
                let previous = Self.aggregate(lastLive.entries, applications: applications,
                                              aliases: state.applicationPaths)
                let latest = Self.aggregate(current.entries, applications: applications,
                                            aliases: state.applicationPaths)
                var newRouteRates: [String: TrafficBytes] = [:]
                for (route, days) in latest.routes {
                    newRouteRates[route] = Self.rate(current: days, previous: previous.routes[route] ?? [:], seconds: seconds)
                }
                var newAppRates: [UUID: TrafficBytes] = [:]
                for (id, days) in latest.applications {
                    newAppRates[id] = Self.rate(current: days, previous: previous.applications[id] ?? [:], seconds: seconds)
                }
                routeRates = newRouteRates
                applicationRates = newAppRates
            }
            live = current
            lastLive = current
            lastRefresh = now
            if stateIsValid { error = nil }
        } catch { self.error = error.localizedDescription }
    }

    private static func rate(current: [String: TrafficBytes], previous: [String: TrafficBytes],
                             seconds: TimeInterval) -> TrafficBytes {
        let currentTotal = current.values.reduce(TrafficBytes(), +)
        let previousTotal = previous.values.reduce(TrafficBytes(), +)
        let delta = currentTotal.after(previousTotal)
        return TrafficBytes(upload: Int64(Double(delta.upload) / seconds),
                            download: Int64(Double(delta.download) / seconds))
    }

    func archive(applications: [RoutedApplication] = []) throws -> TrafficSnapshot {
        guard stateIsValid else { throw TrafficStatisticsError.invalidData }
        var result = state
        for app in applications {
            let bundle = URL(fileURLWithPath: app.bundlePath).standardizedFileURL
            let executable = URL(fileURLWithPath: app.executablePath).standardizedFileURL
            let current = Array(Set([bundle.path, bundle.resolvingSymlinksInPath().path,
                                     executable.path, executable.resolvingSymlinksInPath().path])).sorted()
            let known = result.applicationPaths[app.id.uuidString] ?? []
            result.applicationPaths[app.id.uuidString] =
                Array(known.filter { !current.contains($0) }.suffix(32 - current.count)) + current
        }
        if FileManager.default.fileExists(atPath: Self.liveURL.path) {
            let current = try JSONDecoder().decode(TrafficDocument.self, from: Data(contentsOf: Self.liveURL))
            guard TrafficSnapshot(sources: [current]).valid() else { throw TrafficStatisticsError.invalidData }
            result.sources.removeAll { $0.id == current.id }
            result.sources.append(current)
            return result
        }
        return result
    }

    func restore(_ archive: TrafficSnapshot) throws {
        guard archive.valid() else { throw TrafficStatisticsError.invalidData }
        var restored = archive
        if FileManager.default.fileExists(atPath: Self.liveURL.path) {
            let current = try JSONDecoder().decode(TrafficDocument.self, from: Data(contentsOf: Self.liveURL))
            restored.sources.removeAll { $0.id == current.id }
        }
        try save(restored)
    }

    func resetRoute(_ route: String, applications: [RoutedApplication]) throws {
        guard stateIsValid else { throw TrafficStatisticsError.invalidData }
        var changed = state
        changed.routeResets[route] = Self.aggregate(allEntries(), applications: applications,
                                                   aliases: state.applicationPaths).routes[route] ?? [:]
        try save(changed)
    }

    func resetApplication(_ app: RoutedApplication, applications: [RoutedApplication]) throws {
        guard stateIsValid else { throw TrafficStatisticsError.invalidData }
        var changed = state
        changed.applicationResets[app.id.uuidString] =
            Self.aggregate(allEntries(), applications: applications,
                           aliases: state.applicationPaths).applications[app.id] ?? [:]
        try save(changed)
    }

    private func save(_ snapshot: TrafficSnapshot) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: Self.stateURL, options: .atomic)
        state = snapshot
        stateIsValid = true
        error = nil
    }

    private func allEntries() -> [TrafficEntry] {
        let archived = state.sources.filter { $0.id != live?.id }.flatMap(\.entries)
        return archived + (live?.entries ?? [])
    }

    func totals(applications: [RoutedApplication], period: TrafficPeriod,
                today: String) -> (routes: [String: TrafficBytes], applications: [UUID: TrafficBytes]) {
        Self.totals(snapshot: state, live: live, applications: applications, period: period, today: today)
    }

    static func totals(snapshot: TrafficSnapshot, live: TrafficDocument?, applications: [RoutedApplication],
                       period: TrafficPeriod, today: String) ->
        (routes: [String: TrafficBytes], applications: [UUID: TrafficBytes]) {
        let entries = snapshot.sources.filter { $0.id != live?.id }.flatMap(\.entries) + (live?.entries ?? [])
        let raw = aggregate(entries, applications: applications, aliases: snapshot.applicationPaths)
        func sum(_ days: [String: TrafficBytes], reset: [String: TrafficBytes]) -> TrafficBytes {
            days.filter { period.includes($0.key, today: today) }.reduce(TrafficBytes()) { total, row in
                total + row.value.after(reset[row.key] ?? TrafficBytes())
            }
        }
        var routes: [String: TrafficBytes] = [:]
        for (route, days) in raw.routes {
            routes[route] = sum(days, reset: snapshot.routeResets[route] ?? [:])
        }
        var apps: [UUID: TrafficBytes] = [:]
        for (id, days) in raw.applications {
            apps[id] = sum(days, reset: snapshot.applicationResets[id.uuidString] ?? [:])
        }
        return (routes, apps)
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    static func owner(of entry: TrafficEntry, applications: [RoutedApplication],
                      aliases: [String: [String]] = [:]) -> UUID? {
        for path in entry.paths {
            for app in applications {
                let bundle = URL(fileURLWithPath: app.bundlePath).standardizedFileURL
                let paths = [bundle.path, bundle.resolvingSymlinksInPath().path, app.executablePath]
                    + (aliases[app.id.uuidString] ?? [])
                if paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    return app.id
                }
            }
        }
        return nil
    }

    private static func aggregate(_ entries: [TrafficEntry], applications: [RoutedApplication],
                                  aliases: [String: [String]]) ->
        (routes: [String: [String: TrafficBytes]], applications: [UUID: [String: TrafficBytes]]) {
        var routes: [String: [String: TrafficBytes]] = [:]
        var apps: [UUID: [String: TrafficBytes]] = [:]
        for entry in entries {
            var routeDays = routes[entry.route] ?? [:]
            routeDays[entry.day] = (routeDays[entry.day] ?? TrafficBytes()) + entry.bytes
            routes[entry.route] = routeDays
            if let id = owner(of: entry, applications: applications, aliases: aliases) {
                var appDays = apps[id] ?? [:]
                appDays[entry.day] = (appDays[entry.day] ?? TrafficBytes()) + entry.bytes
                apps[id] = appDays
            }
        }
        return (routes, apps)
    }
}
