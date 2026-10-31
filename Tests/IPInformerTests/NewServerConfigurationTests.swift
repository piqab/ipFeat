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

    func testDeploymentScriptHasValidBashSyntax() throws {
        let script = ServerDeployment.deploymentScript(
            folder: "/tmp/ipinformer-new-example", version: "1.12.0",
            assetName: "sing-box-1.12.0-linux-arm64.tar.gz", sha256: String(repeating: "a", count: 64)
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
        XCTAssertTrue(script.contains("refusing to overwrite"))
        XCTAssertTrue(script.contains("test -x /usr/local/lib/ipinformer-sing-box/sing-box"))
        XCTAssertTrue(script.contains("test \"$actual_version\" = '1.12.0'"))
        XCTAssertTrue(script.contains("set -x"))
    }

    func testDebianPlatformProbeHandlesLoginBannerAndShowsMissingSystemctl() throws {
        let debian = "Welcome to Debian 13\nIPINFORMER_OS=Linux\nIPINFORMER_ARCH=x86_64\nIPINFORMER_SYSTEMCTL=/usr/bin/systemctl\nIPINFORMER_INIT=systemd\n"
        XCTAssertEqual(try ServerDeployment.parsePlatform(debian), "amd64")
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
