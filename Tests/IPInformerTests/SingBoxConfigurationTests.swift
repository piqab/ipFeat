import Foundation
import XCTest
@testable import IPInformer

final class SingBoxConfigurationTests: XCTestCase {
    func testLivePolicyChangesWithoutChangingBaseConfiguration() throws {
        let profile = RoutingProfile(name: "Proxy", outboundTag: "proxy-de")
        var app = application(name: "iTerm", profileID: profile.id)
        app.askChildCommands = true
        let before = RoutingConfiguration(profiles: [profile], mainConfigurationJSON: mainConfiguration)
        var after = before
        after.applications = [app]
        after.childCommandChoices = [ChildCommandChoice(applicationID: app.id,
                                                        executablePath: "/usr/bin/ssh",
                                                        route: .outbound("proxy-us"))]
        let original = try SingBoxConfigurationGenerator.liveConfiguration(for: before)
        let changed = try SingBoxConfigurationGenerator.liveConfiguration(for: after)
        XCTAssertEqual(original.base, changed.base, "Application edits must not restart the TUN")
        XCTAssertNotEqual(original.policy, changed.policy)
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: changed.policy) as? [String: Any])
        let rules = try XCTUnwrap(policy["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["process_path"] as? [String]) == ["/usr/bin/ssh"]
            && $0["ancestor_process_path_regex"] != nil && ($0["outbound"] as? String) == "proxy-us" })
        XCTAssertTrue(rules.contains { rule in
            guard let branches = rule["rules"] as? [[String: Any]] else { return false }
            return branches.contains { $0["ancestor_process_path_regex"] != nil }
        })
        let prompts = try XCTUnwrap(policy["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0]["exclude_process_paths"] as? [String], ["/usr/bin/ssh"])

        if let binary = ProcessInfo.processInfo.environment["IPINFORMER_PATCHED_SING_BOX"] {
            let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-live-\(UUID()).json")
            let policyURL = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-policy-\(UUID()).json")
            defer {
                try? FileManager.default.removeItem(at: baseURL)
                try? FileManager.default.removeItem(at: policyURL)
            }
            try changed.base.write(to: baseURL)
            try changed.policy.write(to: policyURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["check", "-c", baseURL.path, "--ipinformer-policy", policyURL.path]
            let output = Pipe()
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0,
                           String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    func testExplicitGlobalCommandSkipsChildPrompt() throws {
        let profile = RoutingProfile(name: "Proxy", outboundTag: "proxy-us")
        var app = application(name: "iTerm", profileID: profile.id)
        app.askChildCommands = true
        let command = RoutedCommand(name: "ssh", executablePath: "/usr/bin/ssh", profileID: profile.id)
        let config = RoutingConfiguration(profiles: [profile], applications: [app], commands: [command],
                                          mainConfigurationJSON: mainConfiguration)
        let live = try SingBoxConfigurationGenerator.liveConfiguration(for: config)
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: live.policy) as? [String: Any])
        let prompts = try XCTUnwrap(policy["prompts"] as? [[String: Any]])
        XCTAssertTrue((prompts[0]["exclude_process_paths"] as? [String])?.contains("/usr/bin/ssh") == true)
    }

    func testCommandRoutesLocalIPv4BeforeSelectedProxyAndPersists() throws {
        let profile = RoutingProfile(name: "Proxy", outboundTag: "proxy-us")
        let command = RoutedCommand(name: "ssh", executablePath: "/usr/bin/ssh", profileID: profile.id)
        let en0 = try XCTUnwrap(LocalIPv4Network(interface: "en0", address: 0xc0a8_0bf5, mask: 0xffff_ff00))
        let en6 = try XCTUnwrap(LocalIPv4Network(interface: "en6", address: 0xc0a8_4dc8, mask: 0xffff_ff00))
        let config = RoutingConfiguration(profiles: [profile], commands: [command],
                                          mainConfigurationJSON: mainConfiguration,
                                          defaultRoute: .outbound("direct"))
        let decoded = try JSONDecoder().decode(RoutingConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.commands, [command])
        let data = try SingBoxConfigurationGenerator.data(for: decoded, localNetworks: [en0, en6])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let matching = rules.enumerated().filter {
            ($0.element["process_path"] as? [String])?.contains("/usr/bin/ssh") == true
        }
        let lan = try XCTUnwrap(matching.first { ($0.element["ip_cidr"] as? [String]) == [en0.cidr] })
        let fallback = try XCTUnwrap(matching.first { ($0.element["ip_cidr"] as? [String])?.contains("192.168.0.0/16") == true })
        let publicRoute = try XCTUnwrap(matching.first { $0.element["ip_cidr"] == nil })
        XCTAssertEqual(lan.element["outbound"] as? String, en0.outboundTag)
        XCTAssertEqual(fallback.element["outbound"] as? String, SingBoxConfigurationGenerator.localDirectTag)
        XCTAssertEqual(publicRoute.element["outbound"] as? String, "proxy-us")
        XCTAssertLessThan(lan.offset, fallback.offset)
        XCTAssertLessThan(fallback.offset, publicRoute.offset)
        if let binary = NewServerConfiguration.availableBinary() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-command-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
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

    func testCommandWithDefaultRouteOnlyOverridesLocalDestinations() throws {
        let command = RoutedCommand(name: "ssh", executablePath: "/usr/bin/ssh")
        let config = RoutingConfiguration(commands: [command], mainConfigurationJSON: mainConfiguration,
                                          defaultRoute: .outbound("proxy-us"))
        let rules = try XCTUnwrap((root(for: config)["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let commandRules = rules.filter { ($0["process_path"] as? [String])?.contains("/usr/bin/ssh") == true }
        XCTAssertEqual(commandRules.count, 1)
        XCTAssertNotNil(commandRules.first?["ip_cidr"])
        XCTAssertEqual(commandRules.first?["outbound"] as? String, SingBoxConfigurationGenerator.localDirectTag)
        XCTAssertTrue(rules.contains {
            ($0["inbound"] as? [String]) == [SingBoxConfigurationGenerator.managedInboundTag]
                && ($0["outbound"] as? String) == "proxy-us"
        })

        var disabled = config
        disabled.commands[0].enabled = false
        let disabledRules = try XCTUnwrap((root(for: disabled)["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertFalse(disabledRules.contains { $0["process_path"] != nil })
    }

    func testGroupOverridesSavedPersonalProfileUntilAppLeavesGroup() throws {
        let groupProfile = RoutingProfile(name: "Group", outboundTag: "proxy-de")
        let appProfile = RoutingProfile(name: "App", outboundTag: "proxy-us")
        let group = RoutingGroup(id: UUID(), name: "Work", profileID: groupProfile.id)
        let app = application(name: "Browser", groupID: group.id, profileID: appProfile.id)
        let configuration = RoutingConfiguration(
            profiles: [groupProfile, appProfile], groups: [group], applications: [app],
            mainConfigurationJSON: mainConfiguration
        )

        let generated = try root(for: configuration)
        let route = try XCTUnwrap(generated["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first { $0["process_path_regex"] != nil }?["outbound"] as? String, "proxy-de")
        XCTAssertEqual(rules.last?["outbound"] as? String, "direct")
        XCTAssertEqual(SingBoxConfigurationGenerator.probeEndpoints(for: configuration).map(\.outboundTag), ["proxy-de"])

        var ungrouped = configuration
        ungrouped.applications[0].groupID = nil
        let ungroupedRules = try XCTUnwrap((root(for: ungrouped)["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(ungroupedRules.first { $0["process_path_regex"] != nil }?["outbound"] as? String, "proxy-us")
    }

    func testPerApplicationLocalAccessPrecedesGroupProxyAndBlockRoutes() throws {
        let groupProfile = RoutingProfile(name: "Proxy", outboundTag: "proxy-de")
        let personalProfile = RoutingProfile(name: "Personal", outboundTag: "proxy-us")
        let group = RoutingGroup(name: "Work", profileID: groupProfile.id)
        var groupedApp = application(name: "Grouped", groupID: group.id, profileID: personalProfile.id)
        groupedApp.allowLocalNetwork = true
        var blockedApp = application(name: "Blocked", profileID: RoutingProfile.block.id)
        blockedApp.allowLocalNetwork = true
        var defaultApp = application(name: "Default", profileID: nil)
        defaultApp.allowLocalNetwork = true
        let network = try XCTUnwrap(LocalIPv4Network(interface: "en0", address: 0xc0a8_0b64, mask: 0xffff_ff00))
        let configuration = RoutingConfiguration(
            profiles: [groupProfile, personalProfile, .block], groups: [group],
            applications: [groupedApp, blockedApp, defaultApp],
            mainConfigurationJSON: mainConfiguration, defaultRoute: .block
        )
        let data = try SingBoxConfigurationGenerator.data(for: configuration, localNetworks: [network])
        let generated = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rules = try XCTUnwrap((generated?["route"] as? [String: Any])?["rules"] as? [[String: Any]])

        for app in [groupedApp, blockedApp, defaultApp] {
            let matching = rules.enumerated().filter { matches(app.executablePath, rule: $0.element) }
            let connected = try XCTUnwrap(matching.first { ($0.element["ip_cidr"] as? [String]) == [network.cidr] })
            let privateFallback = try XCTUnwrap(matching.first { ($0.element["ip_cidr"] as? [String])?.contains("192.168.0.0/16") == true })
            XCTAssertEqual(connected.element["outbound"] as? String, network.outboundTag)
            XCTAssertEqual(privateFallback.element["outbound"] as? String, SingBoxConfigurationGenerator.localDirectTag)
            XCTAssertLessThan(connected.offset, privateFallback.offset)
            XCTAssertFalse(matching.contains { $0.element["ip_cidr"] == nil &&
                ($0.element["outbound"] as? String) == SingBoxConfigurationGenerator.localDirectTag })
        }
        let groupProxy = try XCTUnwrap(rules.firstIndex { matches(groupedApp.executablePath, rule: $0)
            && ($0["outbound"] as? String) == "proxy-de" })
        let localGroup = try XCTUnwrap(rules.firstIndex { matches(groupedApp.executablePath, rule: $0)
            && ($0["outbound"] as? String) == network.outboundTag })
        XCTAssertLessThan(localGroup, groupProxy)
        XCTAssertFalse(rules.contains { matches(groupedApp.executablePath, rule: $0)
            && ($0["outbound"] as? String) == "proxy-us" })
        let blockReject = try XCTUnwrap(rules.firstIndex { matches(blockedApp.executablePath, rule: $0)
            && ($0["action"] as? String) == "reject" })
        let blockLocal = try XCTUnwrap(rules.firstIndex { matches(blockedApp.executablePath, rule: $0)
            && ($0["outbound"] as? String) == network.outboundTag })
        XCTAssertLessThan(blockLocal, blockReject)

        if let binary = NewServerConfiguration.availableBinary() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-local-access-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["check", "-c", url.path]
            let errorOutput = Pipe()
            process.standardError = errorOutput
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0,
                           String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    func testLocalAccessFlagDefaultsOffInOlderApplicationData() throws {
        let app = application(name: "Old", profileID: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        object.removeValue(forKey: "allowLocalNetwork")
        let decoded = try JSONDecoder().decode(RoutedApplication.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.allowLocalNetwork)
        var updated = decoded
        updated.allowLocalNetwork = true
        XCTAssertTrue(try JSONDecoder().decode(RoutedApplication.self, from: JSONEncoder().encode(updated)).allowLocalNetwork)
    }

    func testManagedRulesComeBeforeMainConfigurationRules() throws {
        let profile = RoutingProfile(name: "VPN", outboundTag: "proxy-de")
        let configuration = RoutingConfiguration(
            profiles: [profile], applications: [application(name: "One", profileID: profile.id)],
            mainConfigurationJSON: mainConfiguration
        )

        let root = try root(for: configuration)
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 9)
        XCTAssertEqual(rules[2]["inbound"] as? [String], [SingBoxConfigurationGenerator.updaterInboundTag])
        XCTAssertEqual(rules[4]["outbound"] as? String, "proxy-de")
        XCTAssertEqual(rules[4]["inbound"] as? [String], ["ipinformer-probe-1"])
        XCTAssertNotNil(rules[6]["process_path_regex"])
        XCTAssertEqual(rules[7]["inbound"] as? [String], [SingBoxConfigurationGenerator.managedInboundTag])
        XCTAssertEqual(rules[7]["outbound"] as? String, "direct")
        XCTAssertEqual(rules[8]["outbound"] as? String, "direct")
    }

    func testSelectedDefaultRouteCoversUnassignedAppsBeforeImportedRules() throws {
        let unassigned = application(name: "Ordinary", profileID: nil)
        let configuration = RoutingConfiguration(
            applications: [unassigned], mainConfigurationJSON: mainConfiguration,
            defaultRoute: .outbound("proxy-us")
        )
        let root = try root(for: configuration)
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(route["final"] as? String, "proxy-us")
        XCTAssertTrue(rules.contains {
            ($0["inbound"] as? [String]) == [SingBoxConfigurationGenerator.managedInboundTag]
                && ($0["outbound"] as? String) == "proxy-us"
        })
        XCTAssertEqual(rules.last?["outbound"] as? String, "direct")
        XCTAssertFalse(rules.contains { matches(unassigned.executablePath, rule: $0) })
    }

    func testDefaultRouteChoiceSurvivesPersistence() throws {
        for choice in [DefaultRoute.outbound("proxy-us"), .localOnly, .block] {
            let saved = RoutingConfiguration(defaultRoute: choice)
            let decoded = try JSONDecoder().decode(RoutingConfiguration.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(decoded.defaultRoute, choice)
        }
    }

    func testGroupColorPersistsAndOldGroupsUseBlue() throws {
        let group = RoutingGroup(name: "Work", profileID: nil, color: .orange)
        let decoded = try JSONDecoder().decode(RoutingGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(decoded.color, .orange)

        let oldJSON = """
        {"id":"\(group.id.uuidString)","name":"Work","profileID":null}
        """
        let oldGroup = try JSONDecoder().decode(RoutingGroup.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(oldGroup.color, .blue)
    }

    func testGroupWithoutProfileUsesDefaultEvenWithSavedPersonalProfile() throws {
        let personal = RoutingProfile(name: "Personal", outboundTag: "proxy-us")
        let group = RoutingGroup(name: "Work", profileID: nil)
        let app = application(name: "Browser", groupID: group.id, profileID: personal.id)
        let configuration = RoutingConfiguration(
            profiles: [personal], groups: [group], applications: [app],
            mainConfigurationJSON: mainConfiguration, defaultRoute: .outbound("proxy-de")
        )
        XCTAssertNil(SingBoxConfigurationGenerator.effectiveProfileID(for: app, configuration: configuration))
        XCTAssertEqual(SingBoxConfigurationGenerator.probeEndpoints(for: configuration).map(\.outboundTag), ["proxy-de"])
        let rules = try XCTUnwrap((root(for: configuration)["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.contains { matches(app.executablePath, rule: $0) })
    }

    func testLocalAndBlockedDefaultsRejectUnassignedTunTraffic() throws {
        for choice in [DefaultRoute.localOnly, .block] {
            let configuration = RoutingConfiguration(
                mainConfigurationJSON: mainConfiguration, defaultRoute: choice
            )
            let route = try XCTUnwrap(root(for: configuration)["route"] as? [String: Any])
            let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
            let defaultRules = rules.filter {
                ($0["inbound"] as? [String]) == [SingBoxConfigurationGenerator.managedInboundTag]
                    && $0["ip_version"] == nil
            }
            XCTAssertEqual(defaultRules.last?["action"] as? String, "reject")
            if choice == .localOnly {
                XCTAssertEqual(defaultRules.first?["ip_cidr"] as? [String], ["127.0.0.0/8"])
            } else {
                XCTAssertEqual(defaultRules.count, 1)
            }
        }
    }

    func testWebKitProxyRulePrecedesLocalOnlyDefaultAndPersists() throws {
        let main = mainConfiguration.replacingOccurrences(of: "proxy-us", with: "proxy")
        let configuration = RoutingConfiguration(mainConfigurationJSON: main,
                                                  defaultRoute: .localOnly,
                                                  webKitProxyEnabled: true)
        let decoded = try JSONDecoder().decode(RoutingConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertTrue(decoded.webKitProxyEnabled)
        let rules = try XCTUnwrap((root(for: decoded)["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let webKitIndex = try XCTUnwrap(rules.firstIndex { ($0["process_name"] as? [String]) == ["com.apple.WebKit.Networking"] })
        let defaultIndex = try XCTUnwrap(rules.firstIndex {
            ($0["inbound"] as? [String]) == [SingBoxConfigurationGenerator.managedInboundTag]
                && ($0["action"] as? String) == "reject"
        })
        XCTAssertLessThan(webKitIndex, defaultIndex)
        XCTAssertEqual(rules[webKitIndex]["outbound"] as? String, "proxy")
        XCTAssertEqual(rules[webKitIndex]["inbound"] as? [String], [SingBoxConfigurationGenerator.managedInboundTag])

        let withoutWebKit = RoutingConfiguration(mainConfigurationJSON: main, defaultRoute: .localOnly)
        let otherRules = try XCTUnwrap((root(for: withoutWebKit)["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertFalse(otherRules.contains { $0["process_name"] != nil })
        XCTAssertThrowsError(try root(for: RoutingConfiguration(mainConfigurationJSON: mainConfiguration,
                                                                webKitProxyEnabled: true)))
    }

    func testApplicationRouteIncludesBundledHelpersWithoutMatchingOtherApps() throws {
        let profile = RoutingProfile(name: "VPN", outboundTag: "proxy-de")
        let app = application(name: "Blisk (Dev)", profileID: profile.id)
        let configuration = RoutingConfiguration(
            profiles: [profile], applications: [app], mainConfigurationJSON: mainConfiguration
        )
        let root = try root(for: configuration)
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let managed = try XCTUnwrap(rules.first { ($0["outbound"] as? String) == "proxy-de" && $0["process_path_regex"] != nil })
        XCTAssertTrue(matches(app.executablePath, rule: managed))
        XCTAssertTrue(matches(
            "/Applications/Blisk (Dev).app/Contents/Frameworks/Blisk.framework/Helpers/Blisk Helper.app/Contents/MacOS/Blisk Helper",
            rule: managed
        ))
        XCTAssertFalse(matches("/Applications/Blisk (Dev).app.backup/Contents/MacOS/Blisk", rule: managed))
        XCTAssertFalse(matches("/Applications/Other.app/Contents/MacOS/Other", rule: managed))
    }

    func testUnknownOutboundFailsClosedAtGeneration() {
        let profile = RoutingProfile(name: "Broken", outboundTag: "missing")
        let configuration = RoutingConfiguration(
            profiles: [profile], applications: [application(name: "App", profileID: profile.id)],
            mainConfigurationJSON: mainConfiguration
        )
        XCTAssertThrowsError(try SingBoxConfigurationGenerator.data(for: configuration))
    }

    func testGeneratorPreservesMainConfigurationAndAddsStableTun() throws {
        let root = try root(for: RoutingConfiguration(mainConfigurationJSON: mainConfiguration))
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.first?["interface_name"] as? String, "utun100")
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(dns["strategy"] as? String, "ipv4_only")
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["action"] as? String, "hijack-dns")
        XCTAssertEqual(rules[0]["ip_version"] as? Int, 6)
        XCTAssertEqual(rules[1]["action"] as? String, "reject")
        XCTAssertEqual(rules[1]["ip_version"] as? Int, 6)
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        XCTAssertEqual(experimental["cache_file"] as? [String: Bool], ["enabled": true])
    }

    func testImportedTunIsReplacedButOtherInboundsRemain() throws {
        let json = mainConfiguration.replacingOccurrences(
            of: "\"outbounds\": [",
            with: "\"inbounds\": [{\"type\":\"tun\",\"tag\":\"old-tun\"},{\"type\":\"mixed\",\"tag\":\"mixed-in\",\"listen\":\"127.0.0.1\",\"listen_port\":2080}], \"outbounds\": ["
        )
        let root = try root(for: RoutingConfiguration(mainConfigurationJSON: json))
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.filter { ($0["type"] as? String) == "tun" }.count, 1)
        XCTAssertEqual(inbounds.first?["interface_name"] as? String, "utun100")
        XCTAssertTrue(inbounds.contains { ($0["tag"] as? String) == "mixed-in" })
        XCTAssertFalse(inbounds.contains { ($0["tag"] as? String) == "old-tun" })
    }

    func testGeneratedConfigurationPassesInstalledSingBox() throws {
        let binary = "/opt/homebrew/bin/sing-box"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("sing-box is not installed") }
        let profile = RoutingProfile(name: "Proxy", outboundTag: "proxy-de")
        for defaultRoute in [DefaultRoute.outbound("proxy-us"), .localOnly, .block] {
            let data = try SingBoxConfigurationGenerator.data(for: RoutingConfiguration(
                profiles: [profile], applications: [application(name: "Browser", profileID: profile.id)],
                mainConfigurationJSON: mainConfiguration, defaultRoute: defaultRoute
            ))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-test-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["check", "-c", url.path]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "\(defaultRoute): \(output)")
        }
        let webKitData = try SingBoxConfigurationGenerator.data(for: RoutingConfiguration(
            mainConfigurationJSON: mainConfiguration.replacingOccurrences(of: "proxy-us", with: "proxy"),
            defaultRoute: .localOnly, webKitProxyEnabled: true
        ))
        let webKitURL = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-webkit-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: webKitURL) }
        try webKitData.write(to: webKitURL)
        let webKitCheck = Process()
        webKitCheck.executableURL = URL(fileURLWithPath: binary)
        webKitCheck.arguments = ["check", "-c", webKitURL.path]
        let webKitOutput = Pipe()
        webKitCheck.standardError = webKitOutput
        try webKitCheck.run()
        webKitCheck.waitUntilExit()
        XCTAssertEqual(webKitCheck.terminationStatus, 0,
                       String(decoding: webKitOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testProbePortsStayStableWhenApplicationsChange() throws {
        let profile = RoutingProfile(name: "Shared", outboundTag: "proxy-de")
        let configuration = RoutingConfiguration(
            profiles: [profile],
            applications: [
                application(name: "One", profileID: profile.id),
                application(name: "Two", profileID: profile.id)
            ],
            mainConfigurationJSON: mainConfiguration
        )
        let endpoints = SingBoxConfigurationGenerator.probeEndpoints(for: configuration)
        XCTAssertEqual(endpoints, [
            RouteProbeEndpoint(outboundTag: "proxy-de", inboundTag: "ipinformer-probe-1", port: 39_001)
        ])
        let generated = try root(for: configuration)
        let inbounds = try XCTUnwrap(generated["inbounds"] as? [[String: Any]])
        let probes = inbounds.filter { ($0["tag"] as? String)?.hasPrefix("ipinformer-probe-") == true }
        XCTAssertEqual(probes.count, 3)
        XCTAssertTrue(probes.contains { ($0["tag"] as? String) == "ipinformer-probe-1" &&
            ($0["listen_port"] as? Int) == 39_001 && ($0["type"] as? String) == "socks" })
    }

    func testDisabledApplicationStillHasProbeForItsGroupProfile() throws {
        let profile = RoutingProfile(name: "Group", outboundTag: "proxy-de")
        let group = RoutingGroup(id: UUID(), name: "Work", profileID: profile.id)
        var app = application(name: "Browser", groupID: group.id, profileID: nil)
        app.enabled = false
        let configuration = RoutingConfiguration(
            profiles: [profile], groups: [group], applications: [app],
            mainConfigurationJSON: mainConfiguration
        )

        XCTAssertEqual(SingBoxConfigurationGenerator.probeEndpoints(for: configuration).map(\.outboundTag), ["proxy-de"])
        let generated = try root(for: configuration)
        let inbounds = try XCTUnwrap(generated["inbounds"] as? [[String: Any]])
        XCTAssertTrue(inbounds.contains { ($0["tag"] as? String) == "ipinformer-probe-1" })
        let route = try XCTUnwrap(generated["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.contains { matches(app.executablePath, rule: $0) })
    }

    func testRedirectOverridesTCPAndRejectsQUIC() throws {
        let app = application(name: "Blisk", profileID: RoutingProfile.localNetwork.id)
        let redirect = ApplicationRedirect(
            id: UUID(), applicationID: app.id, sourceDomain: "example.com", sourcePort: 443,
            targetAddress: "192.168.101.200", targetPort: 32445, enabled: true
        )
        let configuration = RoutingConfiguration(
            profiles: [.block, .localOnly, .localNetwork], applications: [app],
            mainConfigurationJSON: mainConfiguration, redirects: [redirect]
        )
        let generated = try root(for: configuration)
        let route = try XCTUnwrap(generated["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let tcp = try XCTUnwrap(rules.first { ($0["override_address"] as? String) == "192.168.101.200" })
        XCTAssertEqual(tcp["override_port"] as? Int, 32445)
        XCTAssertEqual(tcp["outbound"] as? String, "ipinformer-local-direct")
        XCTAssertTrue(matches(
            "/Applications/Blisk.app/Contents/Frameworks/Blisk.framework/Helpers/Blisk Helper.app/Contents/MacOS/Blisk Helper",
            rule: tcp
        ))
        XCTAssertTrue(rules.contains { ($0["network"] as? String) == "udp" && ($0["action"] as? String) == "reject" })
    }

    func testBuiltInBlockProfileRejectsAllApplicationTraffic() throws {
        let app = application(name: "Offline", profileID: RoutingProfile.block.id)
        let generated = try root(for: RoutingConfiguration(
            profiles: [.block, .localOnly, .localNetwork], applications: [app],
            mainConfigurationJSON: mainConfiguration
        ))
        let route = try XCTUnwrap(generated["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains {
            matches("/Applications/Offline.app/Contents/Helpers/Network Helper", rule: $0) &&
            ($0["action"] as? String) == "reject"
        })
    }

    func testLocalNetworkUsesConnectedInterfaceBeforePrivateFallbackAndReject() throws {
        let en0 = try XCTUnwrap(LocalIPv4Network(
            interface: "en0", address: 0xc0a8_0b64, mask: 0xffff_ff00
        ))
        let en6 = try XCTUnwrap(LocalIPv4Network(
            interface: "en6", address: 0xc0a8_4d64, mask: 0xffff_ff00
        ))
        XCTAssertEqual(en0.cidr, "192.168.11.0/24")
        XCTAssertTrue(en0.contains(0xc0a8_0bb9)) // 192.168.11.185
        XCTAssertFalse(en6.contains(0xc0a8_0bb9))

        let app = application(name: "Windows App", profileID: RoutingProfile.localNetwork.id)
        let configuration = RoutingConfiguration(
            profiles: [.block, .localOnly, .localNetwork], applications: [app],
            mainConfigurationJSON: mainConfiguration, defaultRoute: .localOnly
        )
        let data = try SingBoxConfigurationGenerator.data(
            for: configuration, localNetworks: [en6, en0]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let lan = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == en0.outboundTag })
        XCTAssertEqual(lan["type"] as? String, "direct")
        XCTAssertEqual(lan["bind_interface"] as? String, "en0")

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let appRules = rules.filter { matches(app.executablePath, rule: $0) }
        let en0Index = try XCTUnwrap(appRules.firstIndex { ($0["ip_cidr"] as? [String]) == [en0.cidr] })
        let fallbackIndex = try XCTUnwrap(appRules.firstIndex {
            ($0["outbound"] as? String) == SingBoxConfigurationGenerator.localDirectTag
        })
        let rejectIndex = try XCTUnwrap(appRules.firstIndex { ($0["action"] as? String) == "reject" })
        XCTAssertLessThan(en0Index, fallbackIndex)
        XCTAssertLessThan(fallbackIndex, rejectIndex)
        XCTAssertEqual(appRules[en0Index]["outbound"] as? String, en0.outboundTag)

        let binary = "/opt/homebrew/bin/sing-box"
        if FileManager.default.isExecutableFile(atPath: binary) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-lan-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["check", "-c", url.path]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, output)
        }
    }

    func testRedirectConfigurationPassesInstalledSingBox() throws {
        let binary = "/opt/homebrew/bin/sing-box"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("sing-box is not installed") }
        let app = application(name: "Blisk", profileID: RoutingProfile.localNetwork.id)
        let data = try SingBoxConfigurationGenerator.data(for: RoutingConfiguration(
            profiles: [.block, .localOnly, .localNetwork], applications: [app],
            mainConfigurationJSON: mainConfiguration,
            redirects: [ApplicationRedirect(
                id: UUID(), applicationID: app.id, sourceDomain: "example.com", sourcePort: 443,
                targetAddress: "192.168.101.200", targetPort: 32445, enabled: true
            )]
        ))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-redirect-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["check", "-c", url.path]
        let pipe = Pipe(); process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    private var mainConfiguration: String {
        """
        {
          "dns": {"servers": [{"type": "local", "tag": "dns-default"}], "final": "dns-default"},
          "outbounds": [
            {"type": "direct", "tag": "direct"},
            {"type": "direct", "tag": "proxy-de"},
            {"type": "direct", "tag": "proxy-us"}
          ],
          "route": {
            "rules": [{"ip_is_private": true, "action": "route", "outbound": "direct"}],
            "final": "direct",
            "auto_detect_interface": true,
            "default_domain_resolver": "dns-default"
          },
          "experimental": {"cache_file": {"enabled": true}}
        }
        """
    }

    private func application(name: String, groupID: UUID? = nil, profileID: UUID?) -> RoutedApplication {
        RoutedApplication(
            id: UUID(), name: name, bundlePath: "/Applications/\(name).app",
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            bundleIdentifier: "test.\(name.lowercased())", groupID: groupID, profileID: profileID,
            enabled: true, launchAfterEngineReady: false
        )
    }

    private func root(for configuration: RoutingConfiguration) throws -> [String: Any] {
        let data = try SingBoxConfigurationGenerator.data(for: configuration)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func matches(_ path: String, rule: [String: Any]) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return (rule["process_path_regex"] as? [String] ?? []).contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: path, range: range) != nil
        }
    }
}
