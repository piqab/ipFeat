import Foundation

enum ServerConfigurationCatalog {
    struct MigrationReport {
        let unmanagedTags: [String]
        let missingConnections: [String]
        let unresolvedRoutes: [String]

        var canAdopt: Bool { missingConnections.isEmpty && unresolvedRoutes.isEmpty }
    }

    static func captureExistingOutbounds(_ configuration: RoutingConfiguration) -> RoutingConfiguration {
        var result = configuration
        guard let root = try? rootObject(configuration.mainConfigurationJSON),
              let outbounds = root["outbounds"] as? [[String: Any]] else { return result }
        for index in result.clientConnections.indices where result.clientConnections[index].outboundJSON == nil {
            let tag = result.clientConnections[index].outboundTag
            guard let outbound = outbounds.first(where: { $0["tag"] as? String == tag }),
                  let data = try? JSONSerialization.data(withJSONObject: outbound, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { continue }
            result.clientConnections[index].outboundJSON = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    static func report(_ configuration: RoutingConfiguration) -> MigrationReport {
        let root = try? rootObject(configuration.mainConfigurationJSON)
        let outbounds = root?["outbounds"] as? [[String: Any]] ?? []
        let serverTags = Set(configuration.clientConnections.map(\.outboundTag))
        let managedTags = serverTags.union(["direct"])
        let unmanaged = outbounds.compactMap { $0["tag"] as? String }
            .filter { !managedTags.contains($0) }.sorted()
        let missing = configuration.clientConnections.filter { $0.outboundJSON == nil }
            .map { "\($0.name) (\($0.outboundTag))" }
        var references: [String] = []
        let assignedProfiles = Set(configuration.groups.compactMap(\.profileID)
            + configuration.applications.compactMap(\.profileID)
            + configuration.commands.compactMap(\.profileID)
            + [configuration.webKitProfileID].compactMap { $0 })
        for profile in configuration.profiles where profile.kind == .outbound &&
            !managedTags.contains(profile.outboundTag) && assignedProfiles.contains(profile.id) {
            references.append("Profile: \(profile.name) → \(profile.outboundTag)")
        }
        if case .outbound(let tag)? = configuration.defaultRoute, !managedTags.contains(tag) {
            references.append("Default route → \(tag)")
        }
        if configuration.defaultRoute == nil,
           let route = root?["route"] as? [String: Any],
           let tag = route["final"] as? String, !managedTags.contains(tag) {
            references.append("Default route → \(tag)")
        }
        for choice in configuration.childCommandChoices {
            if case .outbound(let tag) = choice.route, !managedTags.contains(tag) {
                references.append("Child command: \(choice.executablePath) → \(tag)")
            }
        }
        for choice in configuration.savedProcessRoutes {
            if case .outbound(let tag) = choice.route, !managedTags.contains(tag) {
                references.append("Saved process: \(choice.executablePath) → \(tag)")
            }
        }
        if let id = configuration.webKitProfileID,
           !configuration.profiles.contains(where: { $0.id == id }) {
            references.append("WebKit → missing profile")
        } else if configuration.webKitProfileID == nil && configuration.webKitProxyEnabled && !managedTags.contains("proxy") {
            references.append("WebKit → proxy")
        }
        return MigrationReport(unmanagedTags: unmanaged, missingConnections: missing,
                               unresolvedRoutes: references.sorted())
    }

    static func managedJSON(for configuration: RoutingConfiguration) throws -> String {
        var root = try rootObject(RoutingConfiguration.defaultMainConfigurationJSON)
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        var tags = Set(["direct"])
        for connection in configuration.clientConnections {
            guard let json = connection.outboundJSON,
                  let outbound = try? rootObject(json),
                  let tag = outbound["tag"] as? String,
                  tag == connection.outboundTag,
                  tags.insert(tag).inserted else {
                throw failure("Missing or duplicate client outbound: \(connection.name)")
            }
            outbounds.append(outbound)
        }
        root["outbounds"] = outbounds
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func reassignUnavailableRoutes(_ configuration: RoutingConfiguration,
                                          to replacementTag: String) throws -> RoutingConfiguration {
        let retainedTags = Set(configuration.clientConnections.map(\.outboundTag)).union(["direct"])
        guard retainedTags.contains(replacementTag) else { throw failure("Replacement route is unavailable") }
        var result = configuration
        let legacyWebKitProfile = result.webKitProxyEnabled
            ? result.profiles.first(where: { $0.kind == .outbound && $0.outboundTag == "proxy" })?.id : nil
        for index in result.profiles.indices
        where result.profiles[index].kind == .outbound && !retainedTags.contains(result.profiles[index].outboundTag) {
            result.profiles[index].outboundTag = replacementTag
        }
        if case .outbound(let tag)? = result.defaultRoute, !retainedTags.contains(tag) {
            result.defaultRoute = .outbound(replacementTag)
        }
        for index in result.childCommandChoices.indices {
            if case .outbound(let tag) = result.childCommandChoices[index].route, !retainedTags.contains(tag) {
                result.childCommandChoices[index].route = .outbound(replacementTag)
            }
        }
        for index in result.savedProcessRoutes.indices {
            if case .outbound(let tag) = result.savedProcessRoutes[index].route, !retainedTags.contains(tag) {
                result.savedProcessRoutes[index].route = .outbound(replacementTag)
            }
        }
        if result.webKitProxyEnabled {
            result.webKitProfileID = legacyWebKitProfile
                ?? result.profiles.first(where: { $0.kind == .outbound && $0.outboundTag == replacementTag })?.id
            result.webKitProxyEnabled = false
        }
        if let id = result.webKitProfileID,
           !result.profiles.contains(where: { $0.id == id }) {
            result.webKitProfileID = result.profiles.first(where: { $0.kind == .outbound && $0.outboundTag == replacementTag })?.id
        }
        return result
    }

    private static func rootObject(_ json: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw failure("Invalid sing-box JSON")
        }
        return object
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ipFeat.ServerConfigurationCatalog", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
