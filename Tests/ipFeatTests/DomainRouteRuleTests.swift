import Foundation
import XCTest
@testable import ipFeat

final class DomainRouteRuleTests: XCTestCase {
    private let main = #"{"outbounds":[{"type":"direct","tag":"direct"},{"type":"socks","tag":"proxy","server":"203.0.113.10","server_port":1080}],"route":{"final":"proxy"}}"#

    func testPatternsMapToStandardSingBoxRules() throws {
        let suffix = DomainRouteRule(pattern: "*.blabla.eu", outboundTag: "proxy")
        let exact = DomainRouteRule(pattern: "blabla.eu", outboundTag: "direct")
        XCTAssertEqual(try suffix.matchFields()["domain_suffix"] as? [String], [".blabla.eu"])
        XCTAssertEqual(try exact.matchFields()["domain"] as? [String], ["blabla.eu"])
        XCTAssertThrowsError(try DomainRouteRule(pattern: "foo.*.com", outboundTag: "direct").matchFields())
        XCTAssertThrowsError(try DomainRouteRule(pattern: "https://example.com/page", outboundTag: "direct").matchFields())
    }

    func testGlobalRulesStayLiveAndPrecedeApplicationRoutes() throws {
        var configuration = RoutingConfiguration(mainConfigurationJSON: main)
        let proxyProfile = RoutingProfile(name: "Proxy", outboundTag: "proxy")
        let blockedProfile = RoutingProfile.block
        configuration.profiles = [proxyProfile, blockedProfile]
        configuration.applications = [
            RoutedApplication(id: UUID(), name: "Browser", bundlePath: "/Applications/Browser.app",
                              executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                              bundleIdentifier: nil, groupID: nil, profileID: proxyProfile.id,
                              enabled: true, launchAfterEngineReady: false),
            RoutedApplication(id: UUID(), name: "Blocked", bundlePath: "/Applications/Blocked.app",
                              executablePath: "/Applications/Blocked.app/Contents/MacOS/Blocked",
                              bundleIdentifier: nil, groupID: nil, profileID: blockedProfile.id,
                              enabled: true, launchAfterEngineReady: false)
        ]
        configuration.domainRules = [
            DomainRouteRule(pattern: "*.com", outboundTag: "direct"),
            DomainRouteRule(pattern: "*.blabla.eu", outboundTag: "proxy")
        ]
        let live = try SingBoxConfigurationGenerator.liveConfiguration(for: configuration)
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: live.policy) as? [String: Any])
        let rules = try XCTUnwrap(policy["rules"] as? [[String: Any]])
        func hasProcessCondition(_ rule: [String: Any]) -> Bool {
            if rule["process_path_regex"] != nil { return true }
            return (rule["rules"] as? [[String: Any]] ?? []).contains(where: hasProcessCondition)
        }
        XCTAssertTrue(rules.contains { $0["action"] as? String == "sniff" })
        XCTAssertTrue(rules.contains { ($0["domain_suffix"] as? [String]) == [".com"]
            && $0["outbound"] as? String == "direct" })
        let domainIndex = try XCTUnwrap(rules.firstIndex { ($0["domain_suffix"] as? [String]) == [".com"] })
        let blockIndex = try XCTUnwrap(rules.firstIndex { $0["action"] as? String == "reject"
            && hasProcessCondition($0) })
        let appIndex = try XCTUnwrap(rules.firstIndex { hasProcessCondition($0)
            && $0["outbound"] as? String == "proxy" })
        XCTAssertLessThan(blockIndex, domainIndex)
        XCTAssertLessThan(domainIndex, appIndex)
        XCTAssertEqual(policy["prompt_bypass_domain_suffixes"] as? [String], [".com", ".blabla.eu"])
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: live.base) as? [String: Any])
        let baseRules = (base["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        XCTAssertFalse(baseRules.contains { $0["domain_suffix"] != nil })
        let decoded = try JSONDecoder().decode(RoutingConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.domainRules, configuration.domainRules)
    }

    func testRemovingServerReassignsOrDisablesItsDomainRules() throws {
        let connection = ClientConnection(name: "Server", outboundTag: "proxy", serverIPv4: "203.0.113.10",
                                          protocolName: "socks", singBoxVersion: "1.14.4")
        var configuration = RoutingConfiguration(mainConfigurationJSON: main)
        configuration.clientConnections = [connection]
        configuration.profiles = [RoutingProfile(name: "Proxy", outboundTag: "proxy"),
                                  RoutingProfile(name: "Direct", outboundTag: "direct"), .block]
        configuration.domainRules = [DomainRouteRule(pattern: "*.example.com", outboundTag: "proxy")]
        let moved = try ClientConnectionRemoval.reroute(configuration, id: connection.id,
            replacementProfileID: configuration.profiles[1].id)
        XCTAssertEqual(moved.domainRules.first?.outboundTag, "direct")
        let blocked = try ClientConnectionRemoval.reroute(configuration, id: connection.id,
            replacementProfileID: configuration.profiles[2].id)
        XCTAssertEqual(blocked.domainRules.first?.enabled, false)
    }

    func testClientJSONCarriesSameDomainRulesAndRequiredOutbounds() throws {
        let connection = ClientConnection(name: "Server", outboundTag: "proxy", serverIPv4: "203.0.113.10",
                                          protocolName: "socks", singBoxVersion: "1.14.4")
        let rules = [DomainRouteRule(pattern: "*.com", outboundTag: "direct"),
                     DomainRouteRule(pattern: "*.blabla.eu", outboundTag: "proxy")]
        let json = try ClientQRS.androidConfiguration(connection: connection, mainJSON: main, domainRules: rules)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(Set(outbounds.compactMap { $0["tag"] as? String }), Set(["direct", "proxy"]))
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let routeRules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(routeRules.contains { ($0["domain_suffix"] as? [String]) == [".com"]
            && $0["outbound"] as? String == "direct" })
        XCTAssertTrue(routeRules.contains { ($0["domain_suffix"] as? [String]) == [".blabla.eu"]
            && $0["outbound"] as? String == "proxy" })
        if let binary = NewServerConfiguration.availableBinary() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipfeat-domain-qrs-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(json.utf8).write(to: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["check", "-c", url.path]
            let output = Pipe()
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0,
                           String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
