import Foundation
import XCTest
@testable import ipFeat

@MainActor
final class TrafficStatisticsTests: XCTestCase {
    func testTrafficWithoutVerifiedOwnerRemainsInRouteTotal() throws {
        let data = Data(#"{"version":1,"id":"sample","updatedAt":"2026-11-24T18:58:00Z","entries":[{"day":"2026-11-24","route":"proxy","paths":null,"upload":12,"download":34},{"day":"2026-11-24","route":"direct","upload":5,"download":6}]}"#.utf8)
        let document = try JSONDecoder().decode(TrafficDocument.self, from: data)
        XCTAssertEqual(document.entries.map(\.paths), [[], []])
        let totals = TrafficStatistics.totals(snapshot: TrafficSnapshot(), live: document,
                                              applications: [], period: .all, today: "2026-11-24")
        XCTAssertEqual(totals.routes["proxy"], TrafficBytes(upload: 12, download: 34))
        XCTAssertEqual(totals.routes["direct"], TrafficBytes(upload: 5, download: 6))
    }

    func testRouteAndProgramResetsAreIndependentAcrossDays() {
        let app = RoutedApplication(id: UUID(), name: "iTerm2", bundlePath: "/Applications/iTerm.app",
                                    executablePath: "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                                    bundleIdentifier: "com.googlecode.iterm2", groupID: nil,
                                    profileID: nil, enabled: true, launchAfterEngineReady: false)
        let source = TrafficDocument(version: 1, id: UUID().uuidString, updatedAt: "2026-11-24T12:00:00Z",
            entries: [
                TrafficEntry(day: "2026-11-23", route: "proxy",
                             paths: ["/usr/bin/curl", app.executablePath], upload: 100, download: 200),
                TrafficEntry(day: "2026-11-24", route: "proxy",
                             paths: ["/usr/bin/curl", app.executablePath], upload: 40, download: 60),
                TrafficEntry(day: "2026-11-24", route: "direct",
                             paths: [app.executablePath], upload: 10, download: 20)
            ])
        var snapshot = TrafficSnapshot(sources: [source])
        snapshot.routeResets["proxy"] = ["2026-11-23": TrafficBytes(upload: 100, download: 200),
                                         "2026-11-24": TrafficBytes(upload: 30, download: 50)]
        snapshot.applicationResets[app.id.uuidString] = ["2026-11-23": TrafficBytes(upload: 100, download: 200),
                                                          "2026-11-24": TrafficBytes(upload: 20, download: 30)]
        let today = TrafficStatistics.totals(snapshot: snapshot, live: nil, applications: [app],
                                             period: .today, today: "2026-11-24")
        XCTAssertEqual(today.routes["proxy"], TrafficBytes(upload: 10, download: 10))
        XCTAssertEqual(today.routes["direct"], TrafficBytes(upload: 10, download: 20))
        XCTAssertEqual(today.applications[app.id], TrafficBytes(upload: 30, download: 50))
        let all = TrafficStatistics.totals(snapshot: snapshot, live: nil, applications: [app],
                                           period: .all, today: "2026-11-24")
        XCTAssertEqual(all.routes["proxy"], TrafficBytes(upload: 10, download: 10))
        XCTAssertEqual(all.applications[app.id], TrafficBytes(upload: 30, download: 50))
    }

    func testRestoredSourceMatchingLiveIDIsNotCountedTwice() {
        let id = UUID().uuidString
        let old = TrafficDocument(version: 1, id: id, updatedAt: "2026-11-24T10:00:00Z",
                                  entries: [TrafficEntry(day: "2026-11-24", route: "proxy", paths: [],
                                                         upload: 10, download: 20)])
        let current = TrafficDocument(version: 1, id: id, updatedAt: "2026-11-24T11:00:00Z",
                                      entries: [TrafficEntry(day: "2026-11-24", route: "proxy", paths: [],
                                                             upload: 15, download: 25)])
        let totals = TrafficStatistics.totals(snapshot: TrafficSnapshot(sources: [old]), live: current,
                                              applications: [], period: .all, today: "2026-11-24")
        XCTAssertEqual(totals.routes["proxy"], TrafficBytes(upload: 15, download: 25))
    }

    func testRestoredTrafficMatchesApplicationAfterPathChanges() {
        let app = RoutedApplication(id: UUID(), name: "Editor", bundlePath: "/Applications/Editor.app",
                                    executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
                                    bundleIdentifier: "test.editor", groupID: nil, profileID: nil,
                                    enabled: true, launchAfterEngineReady: false)
        let oldPath = "/Users/old/Applications/Editor.app/Contents/MacOS/Editor"
        let source = TrafficDocument(version: 1, id: UUID().uuidString, updatedAt: "2026-11-24T12:00:00Z",
                                     entries: [TrafficEntry(day: "2026-11-24", route: "proxy",
                                                            paths: [oldPath], upload: 12, download: 34)])
        var snapshot = TrafficSnapshot(sources: [source])
        snapshot.applicationPaths[app.id.uuidString] = [oldPath]
        let totals = TrafficStatistics.totals(snapshot: snapshot, live: nil, applications: [app],
                                              period: .all, today: "2026-11-24")
        XCTAssertEqual(totals.applications[app.id], TrafficBytes(upload: 12, download: 34))
    }
}
