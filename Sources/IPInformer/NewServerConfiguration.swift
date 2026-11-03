import CryptoKit
import Foundation

struct ServerProtocolOption: Identifiable, Hashable {
    enum Kind: String { case inbound, endpoint }
    let kind: Kind
    let name: String
    let fields: [String]
    let hasClientOutbound: Bool
    var id: String { "\(kind.rawValue):\(name)" }
    var isAutomatic: Bool {
        kind == .inbound && ["vless", "shadowsocks", "vmess", "trojan", "hysteria2", "anytls"].contains(name)
    }
}

enum ServerTLSSource {
    case certificate(domain: String, certificatePEM: String, keyPEM: String)
    case acme(domain: String, email: String)
}

struct GeneratedServerPair {
    let clientOutboundJSON: String
    let serverConfigurationJSON: String
    let outboundTag: String
}

enum NewServerConfiguration {
    static func availableBinary() -> String? {
        ["/Library/Application Support/IPInformer/engines/current", "/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func binaryVersion(binary: String) throws -> String {
        let output = String(decoding: try run(binary, arguments: ["version"]), as: UTF8.self)
        guard let firstLine = output.split(separator: "\n").first,
              firstLine.hasPrefix("sing-box version ") else {
            throw NSError(domain: "IPInformer", code: 23, userInfo: [NSLocalizedDescriptionKey: "Не удалось определить версию исполняемого sing-box"])
        }
        return String(firstLine.dropFirst("sing-box version ".count))
    }

    static func protocolOptions(binary: String) throws -> [ServerProtocolOption] {
        let schemaData = try run(binary, arguments: ["schema"])
        guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let definitions = schema["$defs"] as? [String: Any],
              let inbound = definitions["Inbound"] as? [String: Any],
              let inboundChoices = inbound["oneOf"] as? [[String: Any]] else {
            throw NSError(domain: "IPInformer", code: 10, userInfo: [NSLocalizedDescriptionKey: "Версия sing-box не предоставила список inbound"])
        }
        let outbound = definitions["Outbound"] as? [String: Any]
        let outboundTypes = Set(((outbound?["oneOf"] as? [[String: Any]]) ?? []).compactMap {
            (($0["properties"] as? [String: Any])?["type"] as? [String: Any])?["const"] as? String
        })
        let inboundOptions = inboundChoices.compactMap { choice -> ServerProtocolOption? in
            guard let properties = choice["properties"] as? [String: Any],
                  let type = (properties["type"] as? [String: Any])?["const"] as? String else { return nil }
            return ServerProtocolOption(kind: .inbound, name: type, fields: properties.keys.sorted(),
                                        hasClientOutbound: outboundTypes.contains(type))
        }
        let endpointChoices = ((definitions["Endpoint"] as? [String: Any])?["oneOf"] as? [[String: Any]]) ?? []
        let endpointOptions = endpointChoices.compactMap { choice -> ServerProtocolOption? in
            guard let properties = choice["properties"] as? [String: Any],
                  let type = (properties["type"] as? [String: Any])?["const"] as? String else { return nil }
            return ServerProtocolOption(kind: .endpoint, name: type, fields: properties.keys.sorted(),
                                        hasClientOutbound: outboundTypes.contains(type))
        }
        return (inboundOptions + endpointOptions).sorted { $0.id < $1.id }
    }

    static func generate(name: String, serverIPv4: String, port: Int, protocolName: String,
                         handshakeHost: String, kind: ServerProtocolOption.Kind = .inbound,
                         binary: String, tlsSource: ServerTLSSource? = nil) throws -> GeneratedServerPair {
        guard isIPv4(serverIPv4), (1...65535).contains(port) else {
            throw NSError(domain: "IPInformer", code: 11, userInfo: [NSLocalizedDescriptionKey: "Укажите публичный IPv4 и порт 1–65535"])
        }
        guard kind == .inbound else { throw error("Endpoint не является готовой парой клиент–сервер") }
        let tag = "server-" + UUID().uuidString.lowercased().prefix(8)
        let inbound: [String: Any]
        let outbound: [String: Any]
        switch kind == .inbound ? protocolName : "advanced" {
        case "vless":
            guard validHostname(handshakeHost) else {
                throw NSError(domain: "IPInformer", code: 12, userInfo: [NSLocalizedDescriptionKey: "Для Reality укажите домен TLS-сайта"])
            }
            let output = String(decoding: try run(binary, arguments: ["generate", "reality-keypair"]), as: UTF8.self)
            let values = Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
            })
            guard let privateKey = values["PrivateKey"], let publicKey = values["PublicKey"] else {
                throw NSError(domain: "IPInformer", code: 13, userInfo: [NSLocalizedDescriptionKey: "sing-box не создал ключи Reality"])
            }
            let uuid = UUID().uuidString.lowercased()
            let shortID = Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
                .map { String(format: "%02x", $0) }.joined()
            inbound = [
                "type": "vless", "tag": "server-in", "listen": "0.0.0.0", "listen_port": port,
                "users": [["name": "ipinformer", "uuid": uuid, "flow": "xtls-rprx-vision"]],
                "tls": [
                    "enabled": true, "server_name": handshakeHost,
                    "reality": ["enabled": true,
                                "handshake": ["server": handshakeHost, "server_port": 443],
                                "private_key": privateKey, "short_id": [shortID]]
                ]
            ]
            outbound = [
                "type": "vless", "tag": tag, "server": serverIPv4, "server_port": port,
                "uuid": uuid, "flow": "xtls-rprx-vision", "network": "tcp",
                "tls": ["enabled": true, "server_name": handshakeHost,
                        "reality": ["enabled": true, "public_key": publicKey, "short_id": shortID],
                        "utls": ["enabled": true, "fingerprint": "chrome"]]
            ]
        case "shadowsocks":
            let password = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            inbound = ["type": "shadowsocks", "tag": "server-in", "listen": "0.0.0.0",
                       "listen_port": port, "method": "2022-blake3-aes-128-gcm", "password": password]
            outbound = ["type": "shadowsocks", "tag": tag, "server": serverIPv4,
                        "server_port": port, "method": "2022-blake3-aes-128-gcm", "password": password]
        case "vmess":
            let uuid = UUID().uuidString.lowercased()
            inbound = ["type": "vmess", "tag": "server-in", "listen": "0.0.0.0",
                       "listen_port": port, "users": [["name": "ipinformer", "uuid": uuid, "alterId": 0]]]
            outbound = ["type": "vmess", "tag": tag, "server": serverIPv4,
                        "server_port": port, "uuid": uuid, "security": "auto", "alter_id": 0]
        case "trojan", "hysteria2", "anytls":
            guard let tlsSource else { throw error("Выберите сертификат TLS или ACME для \(protocolName)") }
            let tls = try tlsConfiguration(tlsSource, singBoxVersion: try binaryVersion(binary: binary))
            let password = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            let serverInbound: [String: Any] = [
                "type": protocolName, "tag": "server-in", "listen": "0.0.0.0",
                "listen_port": port, "users": [["name": "ipinformer", "password": password]],
                "tls": tls.server
            ]
            var clientOutbound: [String: Any] = [
                "type": protocolName, "tag": tag, "server": serverIPv4,
                "server_port": port, "password": password, "tls": tls.client
            ]
            if protocolName == "hysteria2" {
                // Hysteria2 uses UDP. Keep the generated transport explicit in the UI.
                clientOutbound["network"] = "udp"
            }
            inbound = serverInbound
            outbound = clientOutbound
        default:
            inbound = ["type": protocolName, "tag": "server-in", "listen": "0.0.0.0", "listen_port": port]
            outbound = ["type": protocolName, "tag": tag, "server": serverIPv4, "server_port": port]
        }
        var server: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": ["strategy": "ipv4_only"],
            "outbounds": [["type": "direct", "tag": "direct"]],
            "route": ["final": "direct"]
        ]
        server["inbounds"] = [inbound]
        let serverJSON = try pretty(server)
        let outboundJSON = try pretty(outbound)
        return GeneratedServerPair(clientOutboundJSON: outboundJSON,
                                   serverConfigurationJSON: serverJSON, outboundTag: tag)
    }

    static func validate(serverJSON: String, outboundJSON: String, binary: String) throws {
        guard let serverObject = try JSONSerialization.jsonObject(with: Data(serverJSON.utf8)) as? [String: Any],
              let outboundObject = try JSONSerialization.jsonObject(with: Data(outboundJSON.utf8)) as? [String: Any] else {
            throw error("Серверный и клиентский JSON должны быть объектами")
        }
        try rejectExternalFiles(in: serverObject)
        try rejectExternalFiles(in: outboundObject)
        let serverURL = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-server-\(UUID().uuidString).json")
        let clientURL = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-client-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: serverURL)
            try? FileManager.default.removeItem(at: clientURL)
        }
        try Data(serverJSON.utf8).write(to: serverURL, options: .atomic)
        try Data(outboundJSON.utf8).write(to: clientURL, options: .atomic)
        _ = try run(binary, arguments: ["check", "-c", serverURL.path])
        guard let outbound = try JSONSerialization.jsonObject(with: Data(outboundJSON.utf8)) as? [String: Any] else {
            throw NSError(domain: "IPInformer", code: 14, userInfo: [NSLocalizedDescriptionKey: "Клиентский outbound должен быть JSON-объектом"])
        }
        let client: [String: Any] = ["outbounds": [outbound], "route": ["final": outbound["tag"] ?? ""]]
        try Data(try pretty(client).utf8).write(to: clientURL, options: .atomic)
        _ = try run(binary, arguments: ["check", "-c", clientURL.path])
    }

    static func validatePairing(serverJSON: String, outboundJSON: String,
                                serverIPv4: String, port: Int,
                                option: ServerProtocolOption?) throws {
        guard let option, isIPv4(serverIPv4), (1...65535).contains(port),
              let server = try JSONSerialization.jsonObject(with: Data(serverJSON.utf8)) as? [String: Any],
              let client = try JSONSerialization.jsonObject(with: Data(outboundJSON.utf8)) as? [String: Any],
              let tag = client["tag"] as? String, !tag.isEmpty,
              client["type"] as? String == option.name,
              client["server"] as? String == serverIPv4,
              client["server_port"] as? Int == port else {
            throw NSError(domain: "IPInformer", code: 15, userInfo: [NSLocalizedDescriptionKey:
                "Клиентский outbound должен содержать выбранные тип, публичный IPv4 и порт сервера"])
        }
        let entries = server[option.kind == .inbound ? "inbounds" : "endpoints"] as? [[String: Any]] ?? []
        guard entries.contains(where: { $0["type"] as? String == option.name &&
            (option.kind == .endpoint || $0["listen_port"] as? Int == port) }) else {
            throw NSError(domain: "IPInformer", code: 16, userInfo: [NSLocalizedDescriptionKey:
                "Серверный JSON не содержит выбранную технологию и порт"])
        }
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = UInt8(part), !part.isEmpty, (part.count == 1 || part.first != "0") else { return false }
            return value <= 255
        }
    }

    private static func validHostname(_ value: String) -> Bool {
        value.count <= 253 && value.contains(".") && value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$"#, options: .regularExpression
        ) != nil
    }

    private static func tlsConfiguration(_ source: ServerTLSSource,
                                         singBoxVersion: String) throws -> (server: [String: Any], client: [String: Any]) {
        switch source {
        case .certificate(let domain, let certificatePEM, let keyPEM):
            guard validHostname(domain), certificatePEM.contains("-----BEGIN CERTIFICATE-----"),
                  keyPEM.contains("-----BEGIN PRIVATE KEY-----") ||
                  keyPEM.contains("-----BEGIN RSA PRIVATE KEY-----") ||
                  keyPEM.contains("-----BEGIN EC PRIVATE KEY-----") else {
                throw error("Укажите домен и действительные PEM-файлы сертификата и закрытого ключа")
            }
            let certLines = certificatePEM.split(whereSeparator: \.isNewline).map(String.init)
            let keyLines = keyPEM.split(whereSeparator: \.isNewline).map(String.init)
            return (["enabled": true, "server_name": domain, "certificate": certLines, "key": keyLines],
                    ["enabled": true, "server_name": domain, "certificate": certLines])
        case .acme(let domain, let email):
            guard validHostname(domain), email.contains("@"), !email.contains(" ") else {
                throw error("Для ACME укажите домен и адрес электронной почты")
            }
            let parts = singBoxVersion.split(separator: ".")
            guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
                throw error("Не удалось определить поддержку ACME в версии sing-box \(singBoxVersion)")
            }
            let fields: [String: Any] = ["domain": [domain], "email": email,
                                         "data_directory": "/etc/ipinformer-sing-box/acme"]
            var serverTLS: [String: Any] = ["enabled": true, "server_name": domain]
            if major > 1 || (major == 1 && minor >= 14) {
                serverTLS["certificate_provider"] = fields.merging(["type": "acme"]) { _, new in new }
            } else {
                serverTLS["acme"] = fields
            }
            return (serverTLS, ["enabled": true, "server_name": domain])
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "IPInformer.NewServerConfiguration", code: 25,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func rejectExternalFiles(in value: Any) throws {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key.hasSuffix("_path"), let path = child as? String, !path.isEmpty {
                    throw error("В JSON указан внешний файл \(key): \(path). Встроите сертификат или другие данные в JSON перед установкой")
                }
                try rejectExternalFiles(in: child)
            }
        } else if let array = value as? [Any] {
            for child in array { try rejectExternalFiles(in: child) }
        }
    }

    private static func pretty(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func run(_ binary: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "IPInformer", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)
            ])
        }
        return data
    }
}
