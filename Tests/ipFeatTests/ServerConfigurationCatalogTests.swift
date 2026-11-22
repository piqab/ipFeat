import XCTest
@testable import ipFeat

final class ServerConfigurationCatalogTests: XCTestCase {
    private let serverTag = "server-one"

    func testCapturesSavedServerOutboundAndRebuildsWithoutLegacyChannels() throws {
        var configuration = RoutingConfiguration()
        configuration.usesManagedServerConfiguration = false
        configuration.clientConnections = [ClientConnection(name: "Server one", outboundTag: serverTag,
            serverIPv4: "192.0.2.1", protocolName: "shadowsocks", singBoxVersion: "1.14.4")]
        configuration.mainConfigurationJSON = #"{"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"old-proxy"},{"type":"shadowsocks","tag":"server-one","server":"192.0.2.1","server_port":443,"password":"secret","method":"2022-blake3-aes-128-gcm"}],"route":{"final":"direct"}}"#

        let captured = ServerConfigurationCatalog.captureExistingOutbounds(configuration)
        XCTAssertNotNil(captured.clientConnections[0].outboundJSON)
        XCTAssertEqual(ServerConfigurationCatalog.report(captured).unmanagedTags, ["old-proxy"])
        let generated = try ServerConfigurationCatalog.managedJSON(for: captured)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(generated.utf8)) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(Set(outbounds.compactMap { $0["tag"] as? String }), ["direct", serverTag])
        XCTAssertEqual(outbounds.first(where: { $0["tag"] as? String == serverTag })?["password"] as? String, "secret")
    }

    func testMigrationRequiresReassignmentOfUsedLegacyRoutes() {
        var configuration = RoutingConfiguration()
        configuration.usesManagedServerConfiguration = false
        configuration.mainConfigurationJSON = #"{"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"old-proxy"}],"route":{"final":"old-proxy"}}"#
        let profile = RoutingProfile(name: "Old", outboundTag: "old-proxy")
        configuration.profiles = [profile]
        configuration.groups = [RoutingGroup(name: "Old group", profileID: profile.id)]
        let report = ServerConfigurationCatalog.report(configuration)
        XCTAssertFalse(report.canAdopt)
        XCTAssertTrue(report.unresolvedRoutes.contains { $0.contains("Profile: Old") })
        XCTAssertTrue(report.unresolvedRoutes.contains { $0.contains("Default route") })
    }

    func testLegacyConnectionWithoutOutboundNeedsRestoration() {
        var configuration = RoutingConfiguration()
        configuration.clientConnections = [ClientConnection(name: "Missing", outboundTag: "missing",
            serverIPv4: "192.0.2.1", protocolName: "vless", singBoxVersion: "1.14.4")]
        let report = ServerConfigurationCatalog.report(configuration)
        XCTAssertFalse(report.canAdopt)
        XCTAssertEqual(report.missingConnections.count, 1)
        XCTAssertThrowsError(try ServerConfigurationCatalog.managedJSON(for: configuration))
    }

    func testReassignsLegacyProfilesAndProcessRoutesBeforeMigration() throws {
        var configuration = RoutingConfiguration()
        let old = RoutingProfile(name: "Old", outboundTag: "old-proxy")
        configuration.profiles = [old]
        configuration.defaultRoute = .outbound("old-proxy")
        configuration.childCommandChoices = [ChildCommandChoice(applicationID: UUID(),
            executablePath: "/usr/bin/curl", route: .outbound("old-proxy"))]
        configuration.savedProcessRoutes = [SavedProcessRoute(executablePath: "/usr/bin/git", route: .outbound("old-proxy"))]
        configuration.webKitProxyEnabled = true
        let resolved = try ServerConfigurationCatalog.reassignUnavailableRoutes(configuration, to: "direct")
        XCTAssertEqual(resolved.profiles[0].outboundTag, "direct")
        XCTAssertEqual(resolved.defaultRoute, .outbound("direct"))
        XCTAssertEqual(resolved.childCommandChoices[0].route, .outbound("direct"))
        XCTAssertEqual(resolved.savedProcessRoutes[0].route, .outbound("direct"))
        XCTAssertFalse(resolved.webKitProxyEnabled)
    }
}
