import Foundation

enum ClientConnectionRemoval {
    static func reroute(_ configuration: RoutingConfiguration, id: UUID,
                        replacementProfileID: UUID) throws -> RoutingConfiguration {
        guard let connection = configuration.clientConnections.first(where: { $0.id == id }) else {
            throw failure("Клиентское подключение не найдено")
        }
        guard let replacement = configuration.profiles.first(where: { $0.id == replacementProfileID }),
              !(replacement.kind == .outbound && replacement.outboundTag == connection.outboundTag),
              replacement.kind != .localNetwork else {
            throw failure("Выберите другой маршрут для программ и групп")
        }
        var candidate = configuration
        let removedProfileIDs = Set(candidate.profiles.filter {
            $0.kind == .outbound && $0.outboundTag == connection.outboundTag
        }.map(\.id))
        for index in candidate.groups.indices where candidate.groups[index].profileID.map(removedProfileIDs.contains) == true {
            candidate.groups[index].profileID = replacementProfileID
        }
        for index in candidate.applications.indices where candidate.applications[index].profileID.map(removedProfileIDs.contains) == true {
            candidate.applications[index].profileID = replacementProfileID
        }
        for index in candidate.commands.indices where candidate.commands[index].profileID.map(removedProfileIDs.contains) == true {
            candidate.commands[index].profileID = replacementProfileID
        }
        if candidate.webKitProfileID.map(removedProfileIDs.contains) == true {
            candidate.webKitProfileID = replacementProfileID
        }
        if candidate.webKitProxyEnabled && connection.outboundTag == "proxy" {
            candidate.webKitProfileID = replacementProfileID
            candidate.webKitProxyEnabled = false
        }
        let replacementRoute: DefaultRoute
        switch replacement.kind {
        case .outbound: replacementRoute = .outbound(replacement.outboundTag)
        case .block: replacementRoute = .block
        case .localOnly, .localNetwork: replacementRoute = .localOnly
        }
        for index in candidate.childCommandChoices.indices {
            if candidate.childCommandChoices[index].route == .outbound(connection.outboundTag) {
                candidate.childCommandChoices[index].route = replacementRoute
            }
        }
        for index in candidate.savedProcessRoutes.indices {
            if candidate.savedProcessRoutes[index].route == .outbound(connection.outboundTag) {
                candidate.savedProcessRoutes[index].route = replacementRoute
            }
        }
        for index in candidate.domainRules.indices where candidate.domainRules[index].outboundTag == connection.outboundTag {
            if replacement.kind == .outbound {
                candidate.domainRules[index].outboundTag = replacement.outboundTag
            } else {
                candidate.domainRules[index].enabled = false
            }
        }
        let mainFinal = (try? JSONSerialization.jsonObject(with: Data(configuration.mainConfigurationJSON.utf8)))
            .flatMap { $0 as? [String: Any] }
            .flatMap { $0["route"] as? [String: Any] }?["final"] as? String
        if candidate.defaultRoute == .outbound(connection.outboundTag)
            || (candidate.defaultRoute == nil && mainFinal == connection.outboundTag) {
            switch replacement.kind {
            case .outbound: candidate.defaultRoute = .outbound(replacement.outboundTag)
            case .block: candidate.defaultRoute = .block
            case .localOnly: candidate.defaultRoute = .localOnly
            case .localNetwork: break
            }
        }
        return candidate
    }

    static func prepare(_ configuration: RoutingConfiguration, id: UUID,
                        replacementProfileID: UUID) throws -> RoutingConfiguration {
        guard let connection = configuration.clientConnections.first(where: { $0.id == id }),
              let replacement = configuration.profiles.first(where: { $0.id == replacementProfileID }) else {
            throw failure("Клиентское подключение или новый маршрут не найдены")
        }
        var candidate = try reroute(configuration, id: id, replacementProfileID: replacementProfileID)
        guard let data = candidate.mainConfigurationJSON.data(using: .utf8),
              var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbounds = document["outbounds"] as? [[String: Any]] else {
            throw failure("Основная конфигурация повреждена")
        }
        let originalCount = outbounds.count
        outbounds.removeAll { ($0["tag"] as? String) == connection.outboundTag }
        var changed = outbounds.count != originalCount
        document["outbounds"] = outbounds
        var route = document["route"] as? [String: Any] ?? [:]
        if route["final"] as? String == connection.outboundTag {
            route["final"] = replacement.kind == .outbound ? replacement.outboundTag
                : (outbounds.first(where: { $0["tag"] as? String == "direct" })?["tag"]
                   ?? outbounds.first?["tag"])
            changed = true
        }
        if let rules = route["rules"] as? [[String: Any]],
           rules.contains(where: { $0["outbound"] as? String == connection.outboundTag }) {
            route["rules"] = rules.compactMap { original -> [String: Any]? in
                guard original["outbound"] as? String == connection.outboundTag else { return original }
                guard replacement.kind == .outbound else { return nil }
                var updated = original
                updated["outbound"] = replacement.outboundTag
                return updated
            }
            changed = true
        }
        if changed {
            document["route"] = route
            let updatedData = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            candidate.mainConfigurationJSON = String(decoding: updatedData, as: UTF8.self)
        }
        let removedProfileIDs = Set(candidate.profiles.filter {
            $0.kind == .outbound && $0.outboundTag == connection.outboundTag
        }.map(\.id))
        candidate.profiles.removeAll { removedProfileIDs.contains($0.id) }
        if connection.outboundTag == "proxy" { candidate.webKitProxyEnabled = false }
        candidate.clientConnections.removeAll { $0.id == id }
        return candidate
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "ipFeat.ClientRemoval", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
