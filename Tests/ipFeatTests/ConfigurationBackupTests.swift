import Foundation
import XCTest
@testable import ipFeat

final class ConfigurationBackupTests: XCTestCase {
    func testClientRemovalReassignsProgramsGroupsAndDefaultRoute() throws {
        let removed = RoutingProfile(name: "VPS", outboundTag: "vps-test")
        let replacement = RoutingProfile(name: "Proxy", outboundTag: "proxy")
        var routing = RoutingConfiguration(
            profiles: [removed, replacement],
            groups: [RoutingGroup(name: "Work", profileID: removed.id)],
            applications: [RoutedApplication(
                id: UUID(), name: "Editor", bundlePath: "/Applications/Editor.app",
                executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
                bundleIdentifier: "example.editor", groupID: nil, profileID: removed.id,
                enabled: true, launchAfterEngineReady: false
            )],
            commands: [RoutedCommand(name: "ssh", executablePath: "/usr/bin/ssh", profileID: removed.id)],
            mainConfigurationJSON: """
            {"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"proxy"},{"type":"direct","tag":"vps-test"}],"route":{"final":"direct"}}
            """,
            defaultRoute: .outbound("vps-test")
        )
        let connection = ClientConnection(name: "VPS", outboundTag: "vps-test",
                                          serverIPv4: "203.0.113.10", protocolName: "vless",
                                          singBoxVersion: "1.12.0")
        routing.clientConnections = [connection]
        routing.webKitProfileID = removed.id
        routing.childCommandChoices = [ChildCommandChoice(applicationID: routing.applications[0].id,
            executablePath: "/usr/bin/curl", route: .outbound("vps-test"))]
        routing.savedProcessRoutes = [SavedProcessRoute(executablePath: "/usr/bin/git", route: .outbound("vps-test"))]
        let result = try ClientConnectionRemoval.prepare(routing, id: connection.id,
                                                         replacementProfileID: replacement.id)
        XCTAssertEqual(result.defaultRoute, .outbound("proxy"))
        XCTAssertEqual(result.groups[0].profileID, replacement.id)
        XCTAssertEqual(result.applications[0].profileID, replacement.id)
        XCTAssertEqual(result.commands[0].profileID, replacement.id)
        XCTAssertEqual(result.webKitProfileID, replacement.id)
        XCTAssertEqual(result.childCommandChoices[0].route, .outbound("proxy"))
        XCTAssertEqual(result.savedProcessRoutes[0].route, .outbound("proxy"))
        XCTAssertTrue(result.clientConnections.isEmpty)
        XCTAssertFalse(result.profiles.contains(where: { $0.id == removed.id }))
        XCTAssertFalse(result.mainConfigurationJSON.contains("vps-test"))
        XCTAssertThrowsError(try ClientConnectionRemoval.prepare(routing, id: connection.id,
                                                                 replacementProfileID: removed.id))
    }

    func testClientRemovalWorksAfterOutboundWasDeletedManually() throws {
        let removed = RoutingProfile(name: "VPS", outboundTag: "server-vps")
        let replacement = RoutingProfile(name: "Proxy", outboundTag: "proxy")
        let connection = ClientConnection(name: "VPS", outboundTag: "server-vps",
                                          serverIPv4: "203.0.113.10", protocolName: "vless",
                                          singBoxVersion: "1.13.0")
        var routing = RoutingConfiguration(
            profiles: [removed, replacement],
            groups: [RoutingGroup(name: "Work", profileID: removed.id)],
            mainConfigurationJSON: """
            {"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"proxy"}],
             "route":{"final":"server-vps","rules":[{"action":"route","outbound":"server-vps","domain":["example.com"]}]}}
            """
        )
        routing.clientConnections = [connection]
        let staged = try ClientConnectionRemoval.reroute(routing, id: connection.id,
                                                         replacementProfileID: replacement.id)
        XCTAssertEqual(staged.defaultRoute, .outbound("proxy"))
        XCTAssertEqual(staged.groups.first?.profileID, replacement.id)
        XCTAssertEqual(staged.clientConnections.count, 1)
        XCTAssertEqual(staged.mainConfigurationJSON, routing.mainConfigurationJSON)

        let result = try ClientConnectionRemoval.prepare(routing, id: connection.id,
                                                         replacementProfileID: replacement.id)
        XCTAssertTrue(result.clientConnections.isEmpty)
        XCTAssertFalse(result.profiles.contains(where: { $0.id == removed.id }))
        XCTAssertEqual(result.defaultRoute, .outbound("proxy"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.mainConfigurationJSON.utf8)) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "proxy")
        XCTAssertEqual((route["rules"] as? [[String: Any]])?.first?["outbound"] as? String, "proxy")
    }

    func testClientRemovalClearsDuplicateOutboundEntries() throws {
        let removed = RoutingProfile(name: "VPS", outboundTag: "server-vps")
        let replacement = RoutingProfile(name: "Direct", outboundTag: "direct")
        let connection = ClientConnection(name: "VPS", outboundTag: "server-vps",
                                          serverIPv4: "203.0.113.10", protocolName: "vless",
                                          singBoxVersion: "1.13.0")
        var routing = RoutingConfiguration(
            profiles: [removed, replacement],
            mainConfigurationJSON: """
            {"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"server-vps"},{"type":"direct","tag":"server-vps"}],
             "route":{"final":"server-vps"}}
            """
        )
        routing.clientConnections = [connection]
        let result = try ClientConnectionRemoval.prepare(routing, id: connection.id,
                                                         replacementProfileID: replacement.id)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.mainConfigurationJSON.utf8)) as? [String: Any])
        XCTAssertEqual((root["outbounds"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "direct")
    }

    func testEncryptedBackupRoundTripRejectsWrongPasswordAndTampering() throws {
        var routing = RoutingConfiguration(defaultRoute: .outbound("proxy"))
        routing.commands = [RoutedCommand(name: "ssh", executablePath: "/usr/bin/ssh")]
        routing.savedProcessRoutes = [SavedProcessRoute(executablePath: "/usr/bin/curl", route: .outbound("proxy"))]
        var connection = ClientConnection(name: "VPS", outboundTag: "server-test",
                                          serverIPv4: "203.0.113.10", protocolName: "vless",
                                          singBoxVersion: "1.12.0")
        connection.outboundJSON = #"{"type":"vless","tag":"server-test","server":"203.0.113.10"}"#
        routing.clientConnections = [connection]
        let aiProfile = ProcessAIProfile(name: "Local model", provider: .ollama,
                                         endpoint: "http://127.0.0.1:11434/api/chat", model: "test-model")
        let pending = PendingServerInstallation(id: UUID(), name: "New VPS", serverIPv4: "203.0.113.11",
            sshPort: 2222, architecture: "amd64", version: "1.12.0", protocolName: "vless",
            outboundTag: "server-pending", clientJSON: #"{"type":"vless"}"#,
            serverJSON: #"{"inbounds":[]}"#, createdAt: Date(timeIntervalSince1970: 2))
        var backup = ConfigurationBackup(
            routing: routing,
            launchAtLogin: true,
            configurationHistory: [ConfigurationRevision(date: Date(timeIntervalSince1970: 1), json: "{\"secret\":\"sample\"}")],
            engineAutoInstall: true,
            serverConfigurations: [connection.id.uuidString: "{\"private_key\":\"secret\"}"],
            processAISettings: ProcessAISettingsSnapshot(
                profiles: [aiProfile], selectedProfileID: aiProfile.id,
                keys: [aiProfile.id.uuidString: "ai-test-secret"]),
            preferredAppLanguage: "zh-Hans",
            pendingServerInstallations: [pending]
        )
        backup.sources = [IPSource(id: UUID(), name: "Retired checker", url: "https://example.com/ip",
                                   isEnabled: true, isBuiltIn: false)]
        backup.checkInterval = 30
        backup.widgetsVisible = true
        backup.widgetOffsets = ["display": "{10, 20}"]
        let encrypted = try ConfigurationArchive.encrypt(backup, password: "correct horse battery staple")
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("sample"))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("private_key"))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("ai-test-secret"))
        let decoded = try ConfigurationArchive.decrypt(encrypted, password: "correct horse battery staple")
        XCTAssertEqual(decoded.routing.defaultRoute, .outbound("proxy"))
        XCTAssertNil(decoded.sources)
        XCTAssertNil(decoded.checkInterval)
        XCTAssertNil(decoded.widgetsVisible)
        XCTAssertNil(decoded.widgetOffsets)
        XCTAssertEqual(decoded.configurationHistory.first?.json, backup.configurationHistory.first?.json)
        XCTAssertEqual(decoded.engineAutoInstall, true)
        XCTAssertEqual(decoded.preferredAppLanguage, "zh-Hans")
        XCTAssertEqual(decoded.routing.clientConnections, [connection])
        XCTAssertEqual(decoded.routing.commands, routing.commands)
        XCTAssertEqual(decoded.routing.savedProcessRoutes, routing.savedProcessRoutes)
        XCTAssertEqual(decoded.routing.clientConnections[0].outboundJSON, connection.outboundJSON)
        XCTAssertEqual(decoded.serverConfigurations, backup.serverConfigurations)
        XCTAssertEqual(decoded.processAISettings?.profiles, [aiProfile])
        XCTAssertEqual(decoded.processAISettings?.keys[aiProfile.id.uuidString], "ai-test-secret")
        XCTAssertEqual(decoded.pendingServerInstallations, [pending])
        XCTAssertThrowsError(try ConfigurationArchive.decrypt(encrypted, password: "wrong password"))

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encrypted) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["sealedData"] as? String)))
        sealed[sealed.startIndex] ^= 1
        envelope["sealedData"] = sealed.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try ConfigurationArchive.decrypt(tampered, password: "correct horse battery staple"))
    }

    func testNewArchiveRejectsMissingServerSecret() throws {
        var routing = RoutingConfiguration()
        routing.clientConnections = [ClientConnection(name: "VPS", outboundTag: "server-test",
            serverIPv4: "203.0.113.10", protocolName: "vless", singBoxVersion: "1.12.0")]
        let backup = ConfigurationBackup(routing: routing, launchAtLogin: false, configurationHistory: [])
        XCTAssertThrowsError(try ConfigurationArchive.encrypt(backup, password: "strong-password"))
    }

    func testVersionOneArchiveRemainsReadable() throws {
        var backup = ConfigurationBackup(routing: RoutingConfiguration(),
            sources: [IPSource(id: UUID(), name: "Old source", url: "https://example.com/ip",
                               isEnabled: true, isBuiltIn: false)],
            checkInterval: 30, widgetsVisible: true, widgetOffsets: ["widgetOffset.1": "{10, 20}"],
            launchAtLogin: false, configurationHistory: [])
        backup.version = 1
        let encrypted = try ConfigurationArchive.encrypt(backup, password: "strong-password")
        var legacyEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encrypted) as? [String: Any])
        legacyEnvelope["format"] = "IPInformerEncryptedBackup"
        let restored = try ConfigurationArchive.decrypt(
            JSONSerialization.data(withJSONObject: legacyEnvelope), password: "strong-password"
        )
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.sources?.first?.name, "Old source")
    }

    func testVersionTwoArchiveRemainsReadable() throws {
        var backup = ConfigurationBackup(routing: RoutingConfiguration(),
            sources: [IPSource(id: UUID(), name: "Old source", url: "https://example.com/ip",
                               isEnabled: true, isBuiltIn: false)],
            checkInterval: 60, widgetsVisible: false,
            launchAtLogin: true, configurationHistory: [], pendingServerInstallations: [])
        backup.version = 2
        let encrypted = try ConfigurationArchive.encrypt(backup, password: "strong-password")
        let restored = try ConfigurationArchive.decrypt(encrypted, password: "strong-password")
        XCTAssertEqual(restored.version, 2)
        XCTAssertEqual(restored.sources?.first?.name, "Old source")
        XCTAssertEqual(restored.checkInterval, 60)
    }

    func testNewArchiveRejectsPendingInstallationThatIsAlreadyRegistered() throws {
        let id = UUID()
        let connection = ClientConnection(id: id, name: "VPS", outboundTag: "server-test",
            serverIPv4: "203.0.113.10", protocolName: "vless", singBoxVersion: "1.14.4")
        let pending = PendingServerInstallation(id: id, name: "VPS", serverIPv4: "203.0.113.10",
            sshPort: 22, architecture: "amd64", version: "1.14.4", protocolName: "vless",
            outboundTag: "server-test", clientJSON: "{}", serverJSON: "{}", createdAt: Date())
        var routing = RoutingConfiguration()
        routing.clientConnections = [connection]
        let backup = ConfigurationBackup(routing: routing, launchAtLogin: false, configurationHistory: [],
            serverConfigurations: [id.uuidString: "{}"], pendingServerInstallations: [pending])
        XCTAssertThrowsError(try ConfigurationArchive.encrypt(backup, password: "strong-password"))
    }

    func testDiffShowsChangedLines() {
        let lines = ConfigurationDiff.lines(old: "one\ntwo\nthree", new: "one\nchanged\nthree")
        XCTAssertEqual(lines.map(\.marker), [" ", "-", "+", " "])
        XCTAssertEqual(lines.map(\.text), ["one", "two", "changed", "three"])
    }

    @MainActor func testMissingApplicationIsDisabledDuringRestore() {
        let app = RoutedApplication(
            id: UUID(), name: "Missing", bundlePath: "/Applications/ipFeatMissing-123.app",
            executablePath: "/Applications/ipFeatMissing-123.app/Contents/MacOS/Missing",
            bundleIdentifier: "invalid.ipfeat.missing-123", groupID: nil, profileID: nil,
            enabled: true, launchAfterEngineReady: false
        )
        let result = RoutingStore.prepareRestoredConfiguration(RoutingConfiguration(applications: [app]))
        XCTAssertEqual(result.missingApplications, ["Missing"])
        XCTAssertFalse(result.configuration.applications[0].enabled)
    }

    @MainActor func testRestoredServerNeedsFreshRemoteVerification() {
        var connection = ClientConnection(name: "VPS", outboundTag: "server-test",
            serverIPv4: "203.0.113.10", protocolName: "vless", singBoxVersion: "1.14.4")
        connection.installationVerified = true
        connection.installationCheckedAt = Date()
        var routing = RoutingConfiguration()
        routing.clientConnections = [connection]
        let restored = RoutingStore.prepareRestoredConfiguration(routing).configuration
        XCTAssertNil(restored.clientConnections[0].installationVerified)
        XCTAssertNil(restored.clientConnections[0].installationCheckedAt)
    }

    @MainActor func testMissingCommandIsDisabledDuringRestore() {
        let missing = RoutedCommand(name: "missing", executablePath: "/usr/bin/ipfeat-missing-command")
        let result = RoutingStore.prepareRestoredConfiguration(RoutingConfiguration(commands: [missing]))
        XCTAssertEqual(result.missingApplications, ["Command: missing"])
        XCTAssertFalse(result.configuration.commands[0].enabled)
    }

    @MainActor func testMissingSavedProcessRouteIsDisabledDuringRestore() {
        var routing = RoutingConfiguration()
        let route = SavedProcessRoute(executablePath: "/usr/bin/ipfeat-missing-process",
                                      route: .outbound("proxy"))
        routing.savedProcessRoutes = [route]
        let result = RoutingStore.prepareRestoredConfiguration(routing)
        XCTAssertEqual(result.missingApplications, ["Saved route: ipfeat-missing-process"])
        XCTAssertFalse(result.configuration.savedProcessRoutes[0].enabled)
    }

    @MainActor func testBatchImportSkipsAppAlreadyInAnotherGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipfeat-app-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingURL = try makeApplication(named: "Existing", in: directory)
        let firstURL = try makeApplication(named: "First", in: directory)
        let secondURL = try makeApplication(named: "Second", in: directory)
        let oldGroup = UUID()
        let newGroup = UUID()
        let existing = RoutedApplication(
            id: UUID(), name: "Existing", bundlePath: existingURL.path,
            executablePath: existingURL.appendingPathComponent("Contents/MacOS/Existing").path,
            bundleIdentifier: "test.ipfeat.Existing", groupID: oldGroup, profileID: nil,
            enabled: true, launchAfterEngineReady: false
        )
        let planned = RoutingStore.planApplicationImports(
            [existingURL, firstURL, secondURL, firstURL], existing: [existing], groupID: newGroup
        )
        XCTAssertTrue(planned.errors.isEmpty)
        XCTAssertEqual(planned.applications.map(\.name), ["First", "Second"])
        XCTAssertTrue(planned.applications.allSatisfy { $0.groupID == newGroup })
        XCTAssertTrue(planned.applications.allSatisfy(\.askChildCommands))
        XCTAssertFalse(planned.applications.contains { $0.bundlePath == existingURL.path })
    }

    @MainActor func testSelfApplicationStartsOnProxyAndFollowsBundleMove() {
        let proxy = RoutingProfile(name: "Proxy", outboundTag: "proxy")
        var configuration = RoutingConfiguration(profiles: [proxy])
        let first = URL(fileURLWithPath: "/Applications/ipFeat.app")
        RoutingStore.ensureSelfApplication(
            in: &configuration, bundleURL: first,
            executableURL: first.appendingPathComponent("Contents/MacOS/ipFeat")
        )
        XCTAssertEqual(configuration.applications.count, 1)
        XCTAssertEqual(configuration.applications[0].profileID, proxy.id)
        XCTAssertEqual(configuration.applications[0].bundleIdentifier, RoutingStore.selfBundleIdentifier)
        let originalID = configuration.applications[0].id

        let moved = URL(fileURLWithPath: "/Users/test/Applications/ipFeat.app")
        RoutingStore.ensureSelfApplication(
            in: &configuration, bundleURL: moved,
            executableURL: moved.appendingPathComponent("Contents/MacOS/ipFeat")
        )
        XCTAssertEqual(configuration.applications.count, 1)
        XCTAssertEqual(configuration.applications[0].id, originalID)
        XCTAssertEqual(configuration.applications[0].bundlePath, moved.path)
    }

    @MainActor func testLegacySelfApplicationKeepsItsRouteAndIdentityAfterRename() {
        let profile = RoutingProfile(name: "Proxy", outboundTag: "proxy")
        let oldID = UUID()
        let old = RoutedApplication(id: oldID, name: "IP Informer",
            bundlePath: "/Applications/IP Informer.app",
            executablePath: "/Applications/IP Informer.app/Contents/MacOS/IPInformer",
            bundleIdentifier: LegacyDataMigration.oldBundleIdentifier, groupID: nil,
            profileID: profile.id, enabled: true, launchAfterEngineReady: false)
        var configuration = RoutingConfiguration(profiles: [profile], applications: [old])
        RoutingStore.ensureSelfApplication(in: &configuration,
            bundleURL: URL(fileURLWithPath: "/Applications/ipFeat.app"),
            executableURL: URL(fileURLWithPath: "/Applications/ipFeat.app/Contents/MacOS/ipFeat"))
        XCTAssertEqual(configuration.applications.count, 1)
        XCTAssertEqual(configuration.applications[0].id, oldID)
        XCTAssertEqual(configuration.applications[0].profileID, profile.id)
        XCTAssertEqual(configuration.applications[0].bundleIdentifier, RoutingStore.selfBundleIdentifier)
    }

    private func makeApplication(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": "test.ipfeat.\(name)",
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL"
        ]
        XCTAssertTrue(info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        let executable = macOS.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return url
    }
}
