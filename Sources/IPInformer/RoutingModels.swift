import Foundation

enum RoutingProfileKind: String, Codable, Sendable {
    case outbound
    case block
    case localOnly
    case localNetwork
}

enum DefaultRoute: Codable, Hashable, Sendable {
    case outbound(String)
    case localOnly
    case block
}

struct RoutingProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var outboundTag: String
    var kind: RoutingProfileKind
    var legacyInterfaceName: String?
    var legacyOutboundJSON: String?

    init(id: UUID = UUID(), name: String = "Новый профиль", outboundTag: String = "", kind: RoutingProfileKind = .outbound) {
        self.id = id
        self.name = name
        self.outboundTag = outboundTag
        self.kind = kind
        legacyInterfaceName = nil
        legacyOutboundJSON = nil
    }

    // Reads configurations created by the first version too. RoutingStore assigns
    // a valid tag after loading when the old model has no outboundTag field.
    private enum CodingKeys: String, CodingKey { case id, name, outboundTag, kind, interfaceName, outboundJSON }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        outboundTag = try values.decodeIfPresent(String.self, forKey: .outboundTag) ?? ""
        kind = try values.decodeIfPresent(RoutingProfileKind.self, forKey: .kind) ?? .outbound
        legacyInterfaceName = try values.decodeIfPresent(String.self, forKey: .interfaceName)
        legacyOutboundJSON = try values.decodeIfPresent(String.self, forKey: .outboundJSON)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(outboundTag, forKey: .outboundTag)
        try values.encode(kind, forKey: .kind)
    }


    static let block = RoutingProfile(id: UUID(uuidString: "8BB858BB-93AB-4D83-B325-26D45EF0B001")!, name: "Без сети", kind: .block)
    static let localOnly = RoutingProfile(id: UUID(uuidString: "8BB858BB-93AB-4D83-B325-26D45EF0B002")!, name: "Только этот Mac", kind: .localOnly)
    static let localNetwork = RoutingProfile(id: UUID(uuidString: "8BB858BB-93AB-4D83-B325-26D45EF0B003")!, name: "Локальная сеть", kind: .localNetwork)

    var isBuiltIn: Bool { kind != .outbound }
}

struct RoutingGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var profileID: UUID?
    var color: RoutingGroupColor = .blue

    private enum CodingKeys: String, CodingKey { case id, name, profileID, color }

    init(id: UUID = UUID(), name: String, profileID: UUID?, color: RoutingGroupColor = .blue) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        color = try values.decodeIfPresent(RoutingGroupColor.self, forKey: .color) ?? .blue
    }
}

enum RoutingGroupColor: String, CaseIterable, Codable, Sendable {
    case blue, green, orange, purple, red, teal

    var title: String {
        switch self {
        case .blue: return "Синий"
        case .green: return "Зелёный"
        case .orange: return "Оранжевый"
        case .purple: return "Фиолетовый"
        case .red: return "Красный"
        case .teal: return "Бирюзовый"
        }
    }
}

struct RoutedApplication: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var bundlePath: String
    var executablePath: String
    var bundleIdentifier: String?
    var groupID: UUID?
    var profileID: UUID?
    var enabled: Bool
    var launchAfterEngineReady: Bool
    var allowLocalNetwork = false

    private enum CodingKeys: String, CodingKey {
        case id, name, bundlePath, executablePath, bundleIdentifier, groupID, profileID
        case enabled, launchAfterEngineReady, allowLocalNetwork
    }

    init(id: UUID, name: String, bundlePath: String, executablePath: String,
         bundleIdentifier: String?, groupID: UUID?, profileID: UUID?, enabled: Bool,
         launchAfterEngineReady: Bool, allowLocalNetwork: Bool = false) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.groupID = groupID
        self.profileID = profileID
        self.enabled = enabled
        self.launchAfterEngineReady = launchAfterEngineReady
        self.allowLocalNetwork = allowLocalNetwork
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        bundlePath = try values.decode(String.self, forKey: .bundlePath)
        executablePath = try values.decode(String.self, forKey: .executablePath)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        launchAfterEngineReady = try values.decodeIfPresent(Bool.self, forKey: .launchAfterEngineReady) ?? false
        allowLocalNetwork = try values.decodeIfPresent(Bool.self, forKey: .allowLocalNetwork) ?? false
    }
}

struct ApplicationRedirect: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var applicationID: UUID?
    var sourceDomain: String
    var sourcePort: Int
    var targetAddress: String
    var targetPort: Int
    var enabled: Bool
}

struct RoutingConfiguration: Codable, Equatable, Sendable {
    var profiles: [RoutingProfile] = []
    var groups: [RoutingGroup] = []
    var applications: [RoutedApplication] = []
    var singBoxAlwaysOn = true
    var serviceStartsAtBoot = true
    var globalStartupKillSwitch = true
    var mainConfigurationJSON = Self.defaultMainConfigurationJSON
    var defaultRoute: DefaultRoute?
    var webKitProxyEnabled = false
    var selfProxySeeded = false
    var redirects: [ApplicationRedirect] = []
    var clientConnections: [ClientConnection] = []

    private enum CodingKeys: String, CodingKey {
        case profiles, groups, applications, singBoxAlwaysOn, serviceStartsAtBoot
        case globalStartupKillSwitch, mainConfigurationJSON, defaultRoute, webKitProxyEnabled, selfProxySeeded, redirects, clientConnections
    }

    init(
        profiles: [RoutingProfile] = [],
        groups: [RoutingGroup] = [],
        applications: [RoutedApplication] = [],
        singBoxAlwaysOn: Bool = true,
        serviceStartsAtBoot: Bool = true,
        globalStartupKillSwitch: Bool = true,
        mainConfigurationJSON: String = Self.defaultMainConfigurationJSON,
        redirects: [ApplicationRedirect] = [],
        defaultRoute: DefaultRoute? = nil,
        webKitProxyEnabled: Bool = false
    ) {
        self.profiles = profiles
        self.groups = groups
        self.applications = applications
        self.singBoxAlwaysOn = singBoxAlwaysOn
        self.serviceStartsAtBoot = serviceStartsAtBoot
        self.globalStartupKillSwitch = globalStartupKillSwitch
        self.mainConfigurationJSON = mainConfigurationJSON
        self.defaultRoute = defaultRoute
        self.webKitProxyEnabled = webKitProxyEnabled
        self.redirects = redirects
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try values.decodeIfPresent([RoutingProfile].self, forKey: .profiles) ?? []
        groups = try values.decodeIfPresent([RoutingGroup].self, forKey: .groups) ?? []
        applications = try values.decodeIfPresent([RoutedApplication].self, forKey: .applications) ?? []
        singBoxAlwaysOn = try values.decodeIfPresent(Bool.self, forKey: .singBoxAlwaysOn) ?? true
        serviceStartsAtBoot = try values.decodeIfPresent(Bool.self, forKey: .serviceStartsAtBoot) ?? true
        globalStartupKillSwitch = try values.decodeIfPresent(Bool.self, forKey: .globalStartupKillSwitch) ?? true
        mainConfigurationJSON = try values.decodeIfPresent(String.self, forKey: .mainConfigurationJSON)
            ?? Self.defaultMainConfigurationJSON
        defaultRoute = try values.decodeIfPresent(DefaultRoute.self, forKey: .defaultRoute)
        webKitProxyEnabled = try values.decodeIfPresent(Bool.self, forKey: .webKitProxyEnabled) ?? false
        selfProxySeeded = try values.decodeIfPresent(Bool.self, forKey: .selfProxySeeded) ?? false
        redirects = try values.decodeIfPresent([ApplicationRedirect].self, forKey: .redirects) ?? []
        clientConnections = try values.decodeIfPresent([ClientConnection].self, forKey: .clientConnections) ?? []
    }

    static let defaultMainConfigurationJSON = """
    {
      "$schema": "https://sing-box.sagernet.org/schema.json",
      "log": {
        "level": "info",
        "timestamp": true
      },
      "dns": {
        "servers": [
          {
            "type": "local",
            "tag": "dns-default"
          }
        ],
        "final": "dns-default"
      },
      "outbounds": [
        {
          "type": "direct",
          "tag": "direct"
        }
      ],
      "route": {
        "rules": [],
        "final": "direct",
        "auto_detect_interface": true,
        "find_process": true,
        "default_domain_resolver": "dns-default"
      }
    }
    """
}

struct ClientConnection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var outboundTag: String
    var serverIPv4: String
    var protocolName: String
    var singBoxVersion: String
    var createdAt = Date()
}

struct ConfigurationRevision: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var json: String
}

struct NetworkInterfaceOption: Identifiable, Hashable, Sendable {
    let name: String
    let displayName: String
    let addresses: [String]
    let isUp: Bool

    var id: String { name }
    var title: String { "\(displayName) (\(name))" }
}

struct RouteProbeEndpoint: Identifiable, Equatable, Sendable {
    let outboundTag: String
    let inboundTag: String
    let port: Int

    var id: String { outboundTag }
}

enum RoutingConfigurationError: LocalizedError, Equatable {
    case missingProfile(String)
    case missingOutbound(String)
    case unknownOutbound(String)
    case invalidMainConfiguration(String)
    case invalidRedirect(String)
    case noExecutable(String)

    var errorDescription: String? {
        switch self {
        case .missingProfile(let app): return "Для \(app) не выбран профиль"
        case .missingOutbound(let profile): return "В профиле «\(profile)» не выбран outbound"
        case .unknownOutbound(let tag): return "В основной конфигурации не найден outbound «\(tag)»"
        case .invalidMainConfiguration(let reason): return "Ошибка основной конфигурации: \(reason)"
        case .invalidRedirect(let reason): return "Ошибка перенаправления: \(reason)"
        case .noExecutable(let app): return "Не найден исполняемый файл программы «\(app)»"
        }
    }
}
