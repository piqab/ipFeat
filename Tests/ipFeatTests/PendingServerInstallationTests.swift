import Foundation
import XCTest
@testable import ipFeat

final class PendingServerInstallationTests: XCTestCase {
    private func sample() -> PendingServerInstallation {
        PendingServerInstallation(id: UUID(uuidString: "D91D8302-5FCE-4FD6-8A7B-A6F70F011234")!,
            name: "VPS", serverIPv4: "192.0.2.10", sshPort: 2222, architecture: "amd64",
            version: "1.14.4", protocolName: "vless", outboundTag: "server-test",
            clientJSON: #"{"type":"vless","tag":"server-test"}"#,
            serverJSON: #"{"inbounds":[{"type":"vless","uuid":"secret-example"}]}"#,
            createdAt: Date(timeIntervalSince1970: 1))
    }

    func testReceiptMustMatchPendingVersionAndExactConfigurationHash() {
        let pending = sample()
        XCTAssertTrue(pending.accepts("log\n" + pending.receipt + "\n"))
        XCTAssertFalse(pending.accepts(pending.receipt.replacingOccurrences(of: "1.14.4", with: "1.14.3")))
        XCTAssertFalse(pending.accepts(pending.receipt.replacingOccurrences(of: pending.configSHA256,
                                                                            with: String(repeating: "0", count: 64))))
    }

    func testServerAndHostScriptsHaveValidBashSyntaxAndKeepSecretsOutOfCommandLog() throws {
        let pending = sample()
        let server = try pending.serverScript()
        let host = try pending.hostScript()
        XCTAssertFalse(server.contains("secret-example"))
        XCTAssertTrue(server.contains(pending.configSHA256))
        XCTAssertTrue(server.contains(pending.receipt))
        XCTAssertTrue(server.contains("systemctl is-enabled --quiet ipfeat-sing-box.service"))
        XCTAssertTrue(server.contains("base64 -d"))
        XCTAssertTrue(host.contains("curl --ipv4"))
        XCTAssertTrue(host.contains("scp -P"))
        XCTAssertTrue(host.contains("$work/install-on-server.sh"))
        XCTAssertTrue(host.contains("base64.b64decode"), "Copied host installer must contain the VPS script")
        for script in [server, host] {
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
        }
    }

    func testPackageContainsBothScriptsWithPrivatePermissions() throws {
        let pending = sample()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ipfeat-package-test-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let package = parent.appendingPathComponent("package")
        try pending.writePackage(to: package)
        for name in ["install-on-server.sh", "install-from-host.sh"] {
            let path = package.appendingPathComponent(name).path
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
        }
    }

    func testIndependentVerificationRequiresAllServerChecks() throws {
        let hash = String(repeating: "a", count: 64)
        let output = """
        Warning: Permanently added host
        IPFEAT_VERIFY_BEGIN=1
        IPFEAT_VERIFY_HOST=vps-one
        IPFEAT_VERIFY_ARCH=x86_64
        IPFEAT_VERIFY_CONFIG=1
        IPFEAT_VERIFY_UNIT=1
        IPFEAT_VERIFY_BINARY=1
        IPFEAT_VERIFY_HASH=\(hash)
        IPFEAT_VERIFY_VERSION=1.14.4
        IPFEAT_VERIFY_ACTIVE=1
        IPFEAT_VERIFY_ENABLED=1
        IPFEAT_VERIFY_END=1
        --- systemctl status ---
        active

        """
        let verified = try ServerDeployment.parseVerification(output, version: "1.14.4", configSHA256: hash)
        XCTAssertTrue(verified.isInstalled)
        XCTAssertEqual(verified.hostName, "vps-one")
        let missingUnit = output.replacingOccurrences(of: "IPFEAT_VERIFY_UNIT=1", with: "IPFEAT_VERIFY_UNIT=0")
        let failed = try ServerDeployment.parseVerification(missingUnit, version: "1.14.4", configSHA256: hash)
        XCTAssertFalse(failed.isInstalled)
        XCTAssertTrue(failed.summary.contains("systemd unit missing"))
        XCTAssertThrowsError(try ServerDeployment.parseVerification(output.replacingOccurrences(of: "IPFEAT_VERIFY_END=1", with: ""),
                                                                    version: "1.14.4", configSHA256: hash))
    }

    func testOldSavedClientWithoutInstallationFieldsRemainsReadable() throws {
        let oldJSON = """
        {"id":"D91D8302-5FCE-4FD6-8A7B-A6F70F011234","name":"VPS",
         "outboundTag":"server-test","serverIPv4":"192.0.2.10",
         "protocolName":"vless","singBoxVersion":"1.14.4",
         "createdAt":0}
        """
        let decoded = try JSONDecoder().decode(ClientConnection.self, from: Data(oldJSON.utf8))
        XCTAssertNil(decoded.installationVerified)
        XCTAssertNil(decoded.serverArchitecture)
        XCTAssertNil(decoded.serverSSHPort)
    }
}
