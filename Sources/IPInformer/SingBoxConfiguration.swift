import Foundation

enum SingBoxConfigurationGenerator {
    static let managedInboundTag = "ipinformer-tun"
    // Darwin's utun driver only accepts names matching utunN. A high fixed
    // index keeps the PF kill switch deterministic and avoids ordinary VPNs.
    static let managedInterfaceName = "utun100"
    static let localDirectTag = "ipinformer-local-direct"
    static let updaterInboundTag = "ipinformer-updater"
    static let updaterPort = 38_999

    static func data(
        for configuration: RoutingConfiguration,
        localNetworks: [LocalIPv4Network] = []
    ) throws -> Data {
        try build(for: configuration, localNetworks: localNetworks, ancestorMatching: false).data
    }

    static func liveConfiguration(
        for configuration: RoutingConfiguration,
        localNetworks: [LocalIPv4Network] = []
    ) throws -> (base: Data, policy: Data) {
        let live = try build(for: configuration, localNetworks: localNetworks, ancestorMatching: true)
        var baseConfiguration = configuration
        baseConfiguration.applications = []
        baseConfiguration.commands = []
        baseConfiguration.redirects = []
        let base = try build(for: baseConfiguration, localNetworks: localNetworks, ancestorMatching: false).data
        let prompts: [[String: Any]] = configuration.applications.filter { $0.enabled && $0.askChildCommands }.map { app in
            let savedPaths = configuration.childCommandChoices
                .filter { $0.applicationID == app.id }.map(\.executablePath)
            let globalPaths = configuration.commands.filter { $0.enabled && $0.profileID != nil }
                .flatMap { command -> [String] in
                    let url = URL(fileURLWithPath: command.executablePath).standardizedFileURL
                    return [url.path, url.resolvingSymlinksInPath().path]
                }
            return ["application_id": app.id.uuidString,
             "application_name": app.name,
             "process_path_regex": processPathPatterns(for: app),
             "exclude_process_paths": Array(Set(savedPaths + globalPaths)).sorted()]
        }
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IPInformer/child-route.sock").path
        let knownAppPatterns = configuration.applications.flatMap(processPathPatterns)
            + (configuration.webKitProxyEnabled ? ["com\\.apple\\.WebKit\\.Networking"] : [])
        let knownCommandPaths = configuration.commands.flatMap { command -> [String] in
            let url = URL(fileURLWithPath: command.executablePath).standardizedFileURL
            return [url.path, url.resolvingSymlinksInPath().path]
        }
        let policy = try JSONSerialization.data(withJSONObject: ["rules": live.liveRules,
                                                                 "prompts": prompts,
                                                                 "socket_path": socketPath,
                                                                 "ask_unknown_processes": configuration.askUnknownProcesses,
                                                                 "known_process_paths": Array(Set(knownCommandPaths)).sorted(),
                                                                 "known_process_path_regex": Array(Set(knownAppPatterns)).sorted()],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (base, policy)
    }

    private static func build(
        for configuration: RoutingConfiguration,
        localNetworks: [LocalIPv4Network], ancestorMatching: Bool
    ) throws -> (data: Data, liveRules: [[String: Any]]) {
        var root = try parseRoot(configuration.mainConfigurationJSON)
        let availableTags = try outboundTags(in: root)
        var dns = root["dns"] as? [String: Any] ?? [:]
        dns["strategy"] = "ipv4_only"
        root["dns"] = dns
        let enabledApps = configuration.applications.filter(\.enabled)
        let localAccessApps = enabledApps.filter(\.allowLocalNetwork)
        var appsByOutbound: [String: [RoutedApplication]] = [:]
        var blockedApps: [RoutedApplication] = []
        var localOnlyApps: [RoutedApplication] = []
        var localNetworkApps: [RoutedApplication] = []

        for app in enabledApps {
            guard !app.executablePath.isEmpty else { throw RoutingConfigurationError.noExecutable(app.name) }
            guard let profileID = effectiveProfileID(for: app, configuration: configuration) else { continue }
            guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else {
                throw RoutingConfigurationError.missingProfile(app.name)
            }
            switch profile.kind {
            case .block:
                blockedApps.append(app); continue
            case .localOnly:
                localOnlyApps.append(app); continue
            case .localNetwork:
                localNetworkApps.append(app); continue
            case .outbound:
                break
            }
            let tag = profile.outboundTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { throw RoutingConfigurationError.missingOutbound(profile.name) }
            guard availableTags.contains(tag) else { throw RoutingConfigurationError.unknownOutbound(tag) }
            appsByOutbound[tag, default: []].append(app)
        }

        let probeEndpoints = allProbeEndpoints(for: configuration)

        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        outbounds.removeAll { ($0["tag"] as? String) == localDirectTag }
        let connectedNetworks = Array(Set(localNetworks)).sorted {
            if $0.prefixLength != $1.prefixLength { return $0.prefixLength > $1.prefixLength }
            if $0.networkAddress != $1.networkAddress { return $0.networkAddress < $1.networkAddress }
            return $0.interface < $1.interface
        }
        let localInterfaceTags = Set(connectedNetworks.map(\.outboundTag))
        outbounds.removeAll { localInterfaceTags.contains(($0["tag"] as? String) ?? "") }
        outbounds.append(["type": "direct", "tag": localDirectTag])
        for interface in Set(connectedNetworks.map(\.interface)).sorted() {
            outbounds.append([
                "type": "direct", "tag": "ipinformer-lan-\(interface)",
                "bind_interface": interface
            ])
        }
        root["outbounds"] = outbounds

        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        // Imported configurations commonly contain their own TUN. IP Informer
        // owns the only system TUN, so replace every imported TUN while keeping
        // mixed/socks/http and other inbounds intact.
        inbounds.removeAll {
            ($0["type"] as? String) == "tun" || ($0["tag"] as? String) == managedInboundTag
        }
        inbounds.insert([
            "type": "tun",
            "tag": managedInboundTag,
            "interface_name": managedInterfaceName,
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": true,
            "strict_route": true,
            "dns_mode": "hijack"
        ], at: 0)
        for endpoint in probeEndpoints {
            inbounds.append([
                "type": "socks",
                "tag": endpoint.inboundTag,
                "listen": "127.0.0.1",
                "listen_port": endpoint.port
            ])
        }
        inbounds.append([
            "type": "socks", "tag": updaterInboundTag,
            "listen": "127.0.0.1", "listen_port": updaterPort
        ])
        root["inbounds"] = inbounds

        var route = root["route"] as? [String: Any] ?? [:]
        let originalRules = route["rules"] as? [[String: Any]] ?? []
        let infrastructureRules = originalRules.filter {
            guard let action = $0["action"] as? String else { return false }
            return action == "hijack-dns" || action == "sniff"
        }
        let selectedDefault = configuration.defaultRoute ?? .outbound(
            (route["final"] as? String) ?? availableTags.sorted().first ?? ""
        )
        let defaultRules: [[String: Any]]
        switch selectedDefault {
        case .outbound(let selectedTag):
            let tag = selectedTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard availableTags.contains(tag) else { throw RoutingConfigurationError.unknownOutbound(tag) }
            defaultRules = [["inbound": [managedInboundTag], "action": "route", "outbound": tag]]
            route["final"] = tag
        case .localOnly:
            defaultRules = [
                ["inbound": [managedInboundTag], "ip_cidr": ["127.0.0.0/8"], "action": "route", "outbound": localDirectTag],
                ["inbound": [managedInboundTag], "action": "reject"]
            ]
        case .block:
            defaultRules = [["inbound": [managedInboundTag], "action": "reject"]]
        }
        let managedRules: [[String: Any]] = appsByOutbound.keys.sorted().map { tag in
            [
                "process_path_regex": appsByOutbound[tag, default: []]
                    .flatMap(processPathPatterns).sorted(),
                "action": "route",
                "outbound": tag
            ]
        }
        let webKitRules: [[String: Any]]
        if configuration.webKitProxyEnabled {
            guard availableTags.contains("proxy") else { throw RoutingConfigurationError.unknownOutbound("proxy") }
            webKitRules = [[
                "inbound": [managedInboundTag],
                "process_name": ["com.apple.WebKit.Networking"],
                "action": "route", "outbound": "proxy"
            ]]
        } else {
            webKitRules = []
        }
        let redirects = try redirectRules(
            configuration: configuration, enabledApps: enabledApps,
            localNetworks: connectedNetworks
        )
        let commandRules = try commandRules(
            configuration: configuration, availableTags: availableTags,
            localNetworks: connectedNetworks
        )
        let childRules = ancestorMatching
            ? try childCommandRules(configuration: configuration, availableTags: availableTags,
                                    localNetworks: connectedNetworks)
            : []
        let localRules = localAccessRules(
            blockedApps: blockedApps,
            localOnlyApps: localOnlyApps,
            localNetworkApps: localNetworkApps,
            additionalLocalApps: localAccessApps,
            localNetworks: connectedNetworks
        )
        let probeRules: [[String: Any]] = probeEndpoints.map { endpoint in
            [
                "inbound": [endpoint.inboundTag],
                "action": "route",
                "outbound": endpoint.outboundTag
            ]
        }
        let updaterOutbound = availableTags.contains("proxy")
            ? "proxy" : ((route["final"] as? String).flatMap { availableTags.contains($0) ? $0 : nil }
                ?? availableTags.sorted().first ?? "")
        let updaterRule: [[String: Any]] = [[
            "inbound": [updaterInboundTag], "action": "route", "outbound": updaterOutbound
        ]]
        let ipv6Rules: [[String: Any]] = [
            ["inbound": [managedInboundTag], "ip_version": 6, "port": [53], "action": "hijack-dns"],
            ["ip_version": 6, "action": "reject"]
        ]
        let liveRules = ipv6Rules + updaterRule + probeRules
            + (ancestorMatching ? redirects.map(withAncestorMatching) : redirects)
            + childRules
            + commandRules
            + (ancestorMatching ? localRules.map(withAncestorMatching) : localRules)
            + webKitRules
            + (ancestorMatching ? managedRules.map(withAncestorMatching) : managedRules)
        route["rules"] = liveRules + infrastructureRules + defaultRules + originalRules
        route["find_process"] = true
        root["route"] = route

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return (data, liveRules)
    }

    private static func withAncestorMatching(_ rule: [String: Any]) -> [String: Any] {
        guard let patterns = rule["process_path_regex"] as? [String], !patterns.isEmpty else { return rule }
        let actionKeys: Set<String> = ["action", "outbound", "override_address", "override_port"]
        let conditions = rule.filter { !actionKeys.contains($0.key) }
        var ancestor = conditions
        ancestor.removeValue(forKey: "process_path_regex")
        ancestor["ancestor_process_path_regex"] = patterns
        var logical: [String: Any] = ["type": "logical", "mode": "or", "rules": [conditions, ancestor]]
        for key in actionKeys {
            if let value = rule[key] { logical[key] = value }
        }
        return logical
    }

    static func outboundTags(in json: String) throws -> [String] {
        try outboundTags(in: parseRoot(json)).sorted()
    }

    static func defaultRoute(for configuration: RoutingConfiguration) -> DefaultRoute {
        if let selected = configuration.defaultRoute { return selected }
        guard let root = try? parseRoot(configuration.mainConfigurationJSON) else { return .outbound("") }
        let final = (root["route"] as? [String: Any])?["final"] as? String
        let tags = (try? outboundTags(in: root)) ?? []
        return .outbound(final ?? tags.sorted().first ?? "")
    }

    static func probeEndpoints(for configuration: RoutingConfiguration) -> [RouteProbeEndpoint] {
        var tags = Set<String>()
        let availableTags = Set((try? outboundTags(in: configuration.mainConfigurationJSON)) ?? [])
        for app in configuration.applications {
            let tag: String
            if let profileID = effectiveProfileID(for: app, configuration: configuration),
               let profile = configuration.profiles.first(where: { $0.id == profileID }) {
                guard profile.kind == .outbound else { continue }
                tag = profile.outboundTag.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if effectiveProfileID(for: app, configuration: configuration) == nil,
                      case .outbound(let defaultTag) = defaultRoute(for: configuration) {
                tag = defaultTag.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            if availableTags.contains(tag) { tags.insert(tag) }
        }
        return allProbeEndpoints(for: configuration).filter { tags.contains($0.outboundTag) }
    }

    private static func allProbeEndpoints(for configuration: RoutingConfiguration) -> [RouteProbeEndpoint] {
        let availableTags = Set((try? outboundTags(in: configuration.mainConfigurationJSON)) ?? [])
        return probeEndpoints(forOutboundTags: availableTags)
    }

    private static func redirectRules(
        configuration: RoutingConfiguration,
        enabledApps: [RoutedApplication],
        localNetworks: [LocalIPv4Network]
    ) throws -> [[String: Any]] {
        var rules: [[String: Any]] = []
        for redirect in configuration.redirects where redirect.enabled {
            guard let applicationID = redirect.applicationID,
                  let app = enabledApps.first(where: { $0.id == applicationID }) else { continue }
            let domain = redirect.sourceDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let target = redirect.targetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !domain.isEmpty, !domain.contains("/"), !domain.contains(":"),
                  (1...65535).contains(redirect.sourcePort),
                  (1...65535).contains(redirect.targetPort),
                  isPrivateTarget(target) else {
                throw RoutingConfigurationError.invalidRedirect("проверьте домен, порты и локальный адрес для \(app.name)")
            }
            let processPatterns = processPathPatterns(for: app)
            rules.append(["process_path_regex": processPatterns, "action": "sniff"])
            rules.append([
                "process_path_regex": processPatterns, "domain": [domain],
                "port": [redirect.sourcePort], "network": "tcp",
                "action": "route", "outbound": localOutboundTag(for: target, networks: localNetworks),
                "override_address": target, "override_port": redirect.targetPort
            ])
            rules.append([
                "process_path_regex": processPatterns, "domain": [domain],
                "port": [redirect.sourcePort], "network": "udp", "action": "reject"
            ])
        }
        return rules
    }

    private static func localAccessRules(
        blockedApps: [RoutedApplication],
        localOnlyApps: [RoutedApplication],
        localNetworkApps: [RoutedApplication],
        additionalLocalApps: [RoutedApplication],
        localNetworks: [LocalIPv4Network]
    ) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        func patterns(_ apps: [RoutedApplication]) -> [String] {
            apps.flatMap(processPathPatterns).sorted()
        }
        if !additionalLocalApps.isEmpty {
            for network in localNetworks {
                rules.append([
                    "process_path_regex": patterns(additionalLocalApps),
                    "ip_cidr": [network.cidr],
                    "action": "route", "outbound": network.outboundTag
                ])
            }
            rules.append([
                "process_path_regex": patterns(additionalLocalApps),
                "ip_cidr": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.251/32"],
                "action": "route", "outbound": localDirectTag
            ])
        }
        if !localOnlyApps.isEmpty {
            rules.append(["process_path_regex": patterns(localOnlyApps), "ip_cidr": ["127.0.0.0/8", "::1/128"], "action": "route", "outbound": localDirectTag])
            rules.append(["process_path_regex": patterns(localOnlyApps), "action": "reject"])
        }
        if !localNetworkApps.isEmpty {
            for network in localNetworks {
                rules.append([
                    "process_path_regex": patterns(localNetworkApps),
                    "ip_cidr": [network.cidr],
                    "action": "route", "outbound": network.outboundTag
                ])
            }
            rules.append([
                "process_path_regex": patterns(localNetworkApps),
                "ip_cidr": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.251/32", "::1/128", "fc00::/7", "fe80::/10", "ff02::fb/128"],
                "action": "route", "outbound": localDirectTag
            ])
            rules.append(["process_path_regex": patterns(localNetworkApps), "action": "reject"])
        }
        if !blockedApps.isEmpty {
            rules.append(["process_path_regex": patterns(blockedApps), "action": "reject"])
        }
        return rules
    }

    private static func commandRules(
        configuration: RoutingConfiguration,
        availableTags: Set<String>,
        localNetworks: [LocalIPv4Network]
    ) throws -> [[String: Any]] {
        var rules: [[String: Any]] = []
        let privateIPv4 = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                           "192.168.0.0/16", "169.254.0.0/16", "224.0.0.251/32"]
        for command in configuration.commands where command.enabled {
            guard command.executablePath.hasPrefix("/"), !command.executablePath.contains(".app/") else {
                throw RoutingConfigurationError.noExecutable(command.name)
            }
            let url = URL(fileURLWithPath: command.executablePath).standardizedFileURL
            let paths = Array(Set([url.path, url.resolvingSymlinksInPath().path])).sorted()
            let process: [String: Any] = ["process_path": paths]
            let profile: RoutingProfile?
            if let profileID = command.profileID {
                guard let selected = configuration.profiles.first(where: { $0.id == profileID }) else {
                    throw RoutingConfigurationError.missingProfile(command.name)
                }
                profile = selected
            } else {
                profile = nil
            }
            if command.allowLocalNetwork || profile?.kind == .localNetwork {
                for network in localNetworks {
                    rules.append(process.merging([
                        "ip_cidr": [network.cidr], "action": "route", "outbound": network.outboundTag
                    ]) { _, new in new })
                }
                rules.append(process.merging([
                    "ip_cidr": privateIPv4, "action": "route", "outbound": localDirectTag
                ]) { _, new in new })
            }
            guard let profile else { continue }
            switch profile.kind {
            case .outbound:
                let tag = profile.outboundTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard availableTags.contains(tag) else { throw RoutingConfigurationError.unknownOutbound(tag) }
                rules.append(process.merging(["action": "route", "outbound": tag]) { _, new in new })
            case .localOnly:
                if !command.allowLocalNetwork {
                    rules.append(process.merging([
                        "ip_cidr": ["127.0.0.0/8"], "action": "route", "outbound": localDirectTag
                    ]) { _, new in new })
                }
                rules.append(process.merging(["action": "reject"]) { _, new in new })
            case .localNetwork:
                rules.append(process.merging(["action": "reject"]) { _, new in new })
            case .block:
                rules.append(process.merging(["action": "reject"]) { _, new in new })
            }
        }
        return rules
    }

    private static func childCommandRules(
        configuration: RoutingConfiguration,
        availableTags: Set<String>,
        localNetworks: [LocalIPv4Network]
    ) throws -> [[String: Any]] {
        var rules: [[String: Any]] = []
        let privateIPv4 = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                           "192.168.0.0/16", "169.254.0.0/16", "224.0.0.251/32"]
        for choice in configuration.childCommandChoices {
            guard let app = configuration.applications.first(where: {
                $0.id == choice.applicationID && $0.enabled && $0.askChildCommands
            }) else { continue }
            let path = URL(fileURLWithPath: choice.executablePath).standardizedFileURL.path
            let condition: [String: Any] = ["process_path": [path],
                                            "ancestor_process_path_regex": processPathPatterns(for: app)]
            if app.allowLocalNetwork {
                for network in localNetworks {
                    rules.append(condition.merging(["ip_cidr": [network.cidr], "action": "route",
                                                    "outbound": network.outboundTag]) { _, new in new })
                }
                rules.append(condition.merging(["ip_cidr": privateIPv4, "action": "route",
                                                "outbound": localDirectTag]) { _, new in new })
            }
            switch choice.route {
            case .outbound(let tag):
                guard availableTags.contains(tag) else { throw RoutingConfigurationError.unknownOutbound(tag) }
                rules.append(condition.merging(["action": "route", "outbound": tag]) { _, new in new })
            case .localOnly:
                rules.append(condition.merging(["ip_cidr": ["127.0.0.0/8"], "action": "route",
                                                "outbound": localDirectTag]) { _, new in new })
                rules.append(condition.merging(["action": "reject"]) { _, new in new })
            case .block:
                rules.append(condition.merging(["action": "reject"]) { _, new in new })
            }
        }
        return rules
    }

    private static func localOutboundTag(for target: String, networks: [LocalIPv4Network]) -> String {
        let parts = target.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return localDirectTag }
        let address = parts.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return networks.first(where: { $0.contains(address) })?.outboundTag ?? localDirectTag
    }

    private static func processPathPatterns(for app: RoutedApplication) -> [String] {
        let bundleURL = URL(fileURLWithPath: app.bundlePath).standardizedFileURL
        let bundlePaths = Set([bundleURL.path, bundleURL.resolvingSymlinksInPath().path])
        var patterns = bundlePaths.map {
            "^" + NSRegularExpression.escapedPattern(for: $0) + "/.+$"
        }
        if !bundlePaths.contains(where: { app.executablePath.hasPrefix($0 + "/") }) {
            patterns.append("^" + NSRegularExpression.escapedPattern(for: app.executablePath) + "$")
        }
        return Array(Set(patterns)).sorted()
    }

    private static func isPrivateTarget(_ value: String) -> Bool {
        if value == "::1" || value.lowercased().hasPrefix("fc") || value.lowercased().hasPrefix("fd") || value.lowercased().hasPrefix("fe8") { return true }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }

    private static func probeEndpoints(forOutboundTags tags: Set<String>) -> [RouteProbeEndpoint] {
        tags.sorted().enumerated().map { index, tag in
            RouteProbeEndpoint(
                outboundTag: tag,
                inboundTag: "ipinformer-probe-\(index)",
                port: 39_000 + index
            )
        }
    }

    static func effectiveProfileID(for app: RoutedApplication, configuration: RoutingConfiguration) -> UUID? {
        if let groupID = app.groupID,
           let group = configuration.groups.first(where: { $0.id == groupID }) {
            return group.profileID
        }
        return app.profileID
    }

    private static func parseRoot(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8) else {
            throw RoutingConfigurationError.invalidMainConfiguration("текст не является UTF-8")
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RoutingConfigurationError.invalidMainConfiguration("корнем должен быть JSON-объект")
            }
            return root
        } catch let error as RoutingConfigurationError {
            throw error
        } catch {
            throw RoutingConfigurationError.invalidMainConfiguration(error.localizedDescription)
        }
    }

    private static func outboundTags(in root: [String: Any]) throws -> Set<String> {
        guard let outbounds = root["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw RoutingConfigurationError.invalidMainConfiguration("добавьте массив outbounds")
        }
        let tags = outbounds.compactMap { $0["tag"] as? String }.filter { !$0.isEmpty }
        guard tags.count == outbounds.count else {
            throw RoutingConfigurationError.invalidMainConfiguration("каждому outbound нужен уникальный tag")
        }
        guard Set(tags).count == tags.count else {
            throw RoutingConfigurationError.invalidMainConfiguration("теги outbound не должны повторяться")
        }
        return Set(tags)
    }
}
