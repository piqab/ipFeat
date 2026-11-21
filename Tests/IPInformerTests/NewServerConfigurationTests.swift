import Foundation
import XCTest
@testable import IPInformer

final class NewServerConfigurationTests: XCTestCase {
    func testSchemaExposesProtocolsAndGeneratedPairsValidate() throws {
        guard let binary = NewServerConfiguration.availableBinary() else { throw XCTSkip("sing-box unavailable") }
        XCTAssertTrue(try NewServerConfiguration.binaryVersion(binary: binary).range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression
        ) != nil)
        let protocols = try NewServerConfiguration.protocolOptions(binary: binary)
        XCTAssertTrue(protocols.contains(where: { $0.name == "vless" && $0.hasClientOutbound }))
        XCTAssertTrue(protocols.contains(where: { $0.name == "shadowsocks" && $0.hasClientOutbound }))
        XCTAssertTrue(protocols.contains(where: { $0.kind == .endpoint }))
        for name in ["vless", "shadowsocks", "vmess"] {
            let pair = try NewServerConfiguration.generate(
                name: "New VPS", serverIPv4: "203.0.113.10", port: 443,
                protocolName: name, handshakeHost: "www.example.com", binary: binary
            )
            try NewServerConfiguration.validate(
                serverJSON: pair.serverConfigurationJSON,
                outboundJSON: pair.clientOutboundJSON, binary: binary
            )
            let server = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pair.serverConfigurationJSON.utf8)) as? [String: Any])
            let client = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pair.clientOutboundJSON.utf8)) as? [String: Any])
            XCTAssertEqual((server["inbounds"] as? [[String: Any]])?.first?["type"] as? String, name)
            XCTAssertEqual(client["type"] as? String, name)
            XCTAssertEqual(client["server"] as? String, "203.0.113.10")
            try NewServerConfiguration.validatePairing(
                serverJSON: pair.serverConfigurationJSON, outboundJSON: pair.clientOutboundJSON,
                serverIPv4: "203.0.113.10", port: 443,
                option: protocols.first { $0.name == name && $0.kind == .inbound }
            )
            XCTAssertThrowsError(try NewServerConfiguration.validatePairing(
                serverJSON: pair.serverConfigurationJSON, outboundJSON: pair.clientOutboundJSON,
                serverIPv4: "203.0.113.11", port: 443,
                option: protocols.first { $0.name == name && $0.kind == .inbound }
            ))
        }
    }

    func testTLSProtocolsGenerateValidACMEPairsAndRejectMissingFiles() throws {
        guard let binary = NewServerConfiguration.availableBinary() else { throw XCTSkip("sing-box unavailable") }
        let protocols = try NewServerConfiguration.protocolOptions(binary: binary)
        for name in ["trojan", "hysteria2", "anytls"] {
            let option = try XCTUnwrap(protocols.first { $0.kind == .inbound && $0.name == name })
            XCTAssertTrue(option.isAutomatic)
            let pair = try NewServerConfiguration.generate(
                name: "TLS VPS", serverIPv4: "203.0.113.10", port: 443,
                protocolName: name, handshakeHost: "", binary: binary,
                tlsSource: .acme(domain: "example.com", email: "admin@example.com")
            )
            try NewServerConfiguration.validate(serverJSON: pair.serverConfigurationJSON,
                                                outboundJSON: pair.clientOutboundJSON, binary: binary)
            try NewServerConfiguration.validatePairing(serverJSON: pair.serverConfigurationJSON,
                                                       outboundJSON: pair.clientOutboundJSON,
                                                       serverIPv4: "203.0.113.10", port: 443, option: option)
        }
        let external = """
        {"inbounds":[{"type":"trojan","tls":{"certificate_path":"/missing/cert.pem"}}]}
        """
        XCTAssertThrowsError(try NewServerConfiguration.validate(serverJSON: external,
                                                                 outboundJSON: "{}", binary: binary)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Встроите сертификат"))
        }
    }

    func testImportedPEMCertificateIsEmbeddedAndValidates() throws {
        guard let binary = NewServerConfiguration.availableBinary() else { throw XCTSkip("sing-box unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-tls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem")
        let cert = directory.appendingPathComponent("cert.pem")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                             "-subj", "/CN=example.com", "-keyout", key.path, "-out", cert.path]
        openssl.standardError = Pipe()
        try openssl.run()
        openssl.waitUntilExit()
        XCTAssertEqual(openssl.terminationStatus, 0)
        let pair = try NewServerConfiguration.generate(
            name: "PEM VPS", serverIPv4: "203.0.113.10", port: 443,
            protocolName: "trojan", handshakeHost: "", binary: binary,
            tlsSource: .certificate(domain: "example.com",
                                    certificatePEM: String(contentsOf: cert, encoding: .utf8),
                                    keyPEM: String(contentsOf: key, encoding: .utf8)))
        XCTAssertFalse(pair.serverConfigurationJSON.contains("certificate_path"))
        XCTAssertTrue(pair.clientOutboundJSON.contains("BEGIN CERTIFICATE"))
        try NewServerConfiguration.validate(serverJSON: pair.serverConfigurationJSON,
                                            outboundJSON: pair.clientOutboundJSON, binary: binary)
    }

    func testDeploymentScriptHasValidBashSyntax() throws {
        let script = ServerDeployment.deploymentScript(
            folder: "/tmp/ipinformer-new-example", version: "1.12.0",
            assetName: "sing-box-1.12.0-linux-arm64.tar.gz"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertTrue(script.contains("sha256sum -c -"))
        XCTAssertTrue(script.contains("api.github.com/repos/SagerNet/sing-box/releases/tags/v1.12.0"))
        XCTAssertTrue(script.contains("curl --ipv4"))
        XCTAssertTrue(script.contains("refusing to overwrite"))
        XCTAssertTrue(script.contains("test -x /usr/local/lib/ipinformer-sing-box/sing-box"))
        XCTAssertTrue(script.contains("test \"$actual_version\" = '1.12.0'"))
        XCTAssertTrue(script.contains("systemctl enable --now ipinformer-sing-box.service"))
        XCTAssertTrue(script.contains("systemctl is-enabled --quiet ipinformer-sing-box.service"))
        XCTAssertTrue(script.contains("set -x"))
    }

    func testServerReleaseParserRequiresExactTagAssetAndDigest() throws {
        let asset = "sing-box-1.14.4-linux-amd64.tar.gz"
        let script = ServerDeployment.deploymentScript(
            folder: "/tmp/ipinformer-new-example", version: "1.14.4", assetName: asset
        )
        let start = try XCTUnwrap(script.range(of: "<<'PY'\n"))
        let remainder = script[start.upperBound...]
        let end = try XCTUnwrap(remainder.range(of: "\nPY\n"))
        let parser = String(remainder[..<end.lowerBound]) + "\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-release-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        func parse(tag: String, assetName: String, digest: String) throws -> String {
            let release: [String: Any] = [
                "tag_name": tag,
                "assets": [["name": assetName, "digest": digest]]
            ]
            try JSONSerialization.data(withJSONObject: release).write(to: file)
            return try ServerDeployment.run(
                "/usr/bin/env", ["python3", "-", file.path, "v1.14.4", asset],
                input: Data(parser.utf8), authentication: .key("/dev/null")
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let expected = "sha256:" + String(repeating: "a", count: 64)
        XCTAssertEqual(try parse(tag: "v1.14.4", assetName: asset, digest: expected), expected)
        XCTAssertThrowsError(try parse(tag: "v1.14.3", assetName: asset, digest: expected))
        XCTAssertThrowsError(try parse(tag: "v1.14.4", assetName: "other.tar.gz", digest: expected))
    }

    func testDebianPlatformProbeHandlesLoginBannerAndShowsMissingSystemctl() throws {
        let debian = "Welcome to Debian 13\nIPINFORMER_OS=Linux\nIPINFORMER_ARCH=x86_64\nIPINFORMER_SYSTEMCTL=/usr/bin/systemctl\nIPINFORMER_INIT=systemd\n"
        XCTAssertEqual(try ServerDeployment.parsePlatform(debian), "amd64")
        let sshOutput = "Warning: Permanently added '144.172.95.216' (ED25519) to the list of known hosts.\r\n" +
            "\u{001B}[0mIPINFORMER_OS=Linux\r\n" +
            "IPINFORMER_ARCH=x86_64\r\n" +
            "IPINFORMER_SYSTEMCTL=/usr/bin/systemctl\r\n" +
            "IPINFORMER_INIT=systemd\r\n"
        XCTAssertEqual(try ServerDeployment.parsePlatform(sshOutput), "amd64")
        let withoutSystemctl = debian.replacingOccurrences(of: "IPINFORMER_SYSTEMCTL=/usr/bin/systemctl", with: "IPINFORMER_SYSTEMCTL=")
        XCTAssertThrowsError(try ServerDeployment.parsePlatform(withoutSystemctl)) { error in
            XCTAssertTrue(error.localizedDescription.contains("systemctl не найдена"))
        }
        XCTAssertThrowsError(try ServerDeployment.parsePlatform("Welcome to Debian 13\n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Вывод: Welcome to Debian 13"))
        }
    }

    func testRootPasswordIsPassedThroughAskpassWithoutPersistingIt() throws {
        let password = "test-only-password-\(UUID().uuidString)"
        let output = try ServerDeployment.run(
            "/bin/sh", ["-c", "exec \"$SSH_ASKPASS\""],
            authentication: .rootPassword(password)
        )
        XCTAssertEqual(output, password + "\n")
    }

    func testUninstallScriptChecksOwnershipBeforeRemovingFiles() throws {
        let script = ServerDeployment.uninstallScript()
        let result = try ServerDeployment.run("/bin/bash", ["-n"], input: Data(script.utf8),
                                              authentication: .key("/dev/null"))
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(script.contains("grep -Fqx 'ExecStart=/usr/local/lib/ipinformer-sing-box/sing-box run"))
        XCTAssertTrue(script.contains("systemctl disable --now ipinformer-sing-box.service"))
        XCTAssertFalse(script.contains("rm -rf /etc/sing-box"))
    }
}
