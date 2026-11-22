import Foundation
import XCTest
import zlib
@testable import ipFeat

final class ClientQRSTests: XCTestCase {
    func testExportContainsOnlySelectedOutboundAndPassesSingBoxCheck() throws {
        let connection = ClientConnection(name: "Мой сервер", outboundTag: "chosen",
                                          serverIPv4: "203.0.113.10", protocolName: "shadowsocks",
                                          singBoxVersion: "1.13.0")
        let main = #"{"outbounds":[{"type":"direct","tag":"other"},{"type":"shadowsocks","tag":"chosen","server":"203.0.113.10","server_port":443,"method":"2022-blake3-aes-128-gcm","password":"dGVzdC1wYXNzd29yZC0xMg=="}],"server_private_key":"must-not-leak"}"#
        let config = try ClientQRS.androidConfiguration(connection: connection, mainJSON: main)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        XCTAssertEqual(outbounds.first?["tag"] as? String, "chosen")
        XCTAssertFalse(config.contains("must-not-leak"))
        XCTAssertFalse(config.contains("\"other\""))
        XCTAssertEqual((root["dns"] as? [String: Any])?["strategy"] as? String, "ipv4_only")
        XCTAssertEqual((root["inbounds"] as? [[String: Any]])?.first?["type"] as? String, "tun")
        if let binary = NewServerConfiguration.availableBinary() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipfeat-qrs-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(config.utf8).write(to: url)
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

    func testBPFAndMultiFrameQRSRecoverOriginalProfile() throws {
        let config = #"{"outbounds":[{"type":"direct","tag":"proxy"}],"padding":""#
            + (0..<100).map { _ in UUID().uuidString }.joined() + #""}"#
        let profile = try ClientQRS.profileData(name: "Тестовый профиль", config: config)
        let frames = try ClientQRS.frames(profileData: profile)
        XCTAssertGreaterThan(frames.count, 2)

        let prefix = ClientQRS.prefix
        var slices: [Int: Data] = [:]
        var expectedBlocks = 0
        var compressedSize = 0
        var expectedChecksum: UInt32 = 0
        for frame in frames {
            XCTAssertTrue(frame.hasPrefix(prefix))
            let bytes = try XCTUnwrap(Data(base64Encoded: String(frame.dropFirst(prefix.count))))
            let degree = Int(readLE(bytes, 0))
            XCTAssertTrue(degree == 1 || degree == 2)
            let indices = (0..<degree).map { Int(readLE(bytes, 4 + $0 * 4)) }
            expectedBlocks = Int(readLE(bytes, 4 + degree * 4))
            compressedSize = Int(readLE(bytes, 8 + degree * 4))
            expectedChecksum = readLE(bytes, 12 + degree * 4)
            if degree == 1 {
                slices[indices[0]] = bytes.subdata(in: (16 + degree * 4)..<bytes.count)
            }
        }
        XCTAssertEqual(slices.count, expectedBlocks)
        var compressed = Data()
        for index in 0..<expectedBlocks { compressed.append(try XCTUnwrap(slices[index])) }
        compressed = compressed.prefix(compressedSize)
        var output = [UInt8](repeating: 0, count: 100_000)
        var outputSize = uLongf(output.count)
        let status = compressed.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                uncompress(destination.bindMemory(to: Bytef.self).baseAddress, &outputSize,
                           source.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
            }
        }
        XCTAssertEqual(status, Z_OK)
        let file = Data(output.prefix(Int(outputSize)))
        let checksum = file.withUnsafeBytes {
            UInt32(truncatingIfNeeded: crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(file.count)))
        } ^ UInt32(expectedBlocks)
        XCTAssertEqual(checksum, expectedChecksum)
        let metadataSize = Int(readBE(file, 0))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: file.subdata(in: 4..<(4 + metadataSize))) as? [String: String])
        XCTAssertEqual(metadata["filename"], "ipFeat.bpf")
        let dataSize = Int(readBE(file, 4 + metadataSize))
        let unpackedProfile = file.subdata(in: (8 + metadataSize)..<file.count)
        XCTAssertEqual(dataSize, profile.count)
        XCTAssertEqual(unpackedProfile, profile)
        XCTAssertEqual(Array(profile.prefix(4)), [3, 1, 0x1f, 0x8b])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc"]
        let input = Pipe()
        let decoded = Pipe()
        process.standardInput = input
        process.standardOutput = decoded
        try process.run()
        input.fileHandleForWriting.write(profile.dropFirst(2))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let body = decoded.fileHandleForReading.readDataToEndOfFile()
        var offset = 0
        XCTAssertEqual(readString(body, offset: &offset), "Тестовый профиль")
        XCTAssertEqual(readBE(body, offset), 0)
        offset += 4
        XCTAssertEqual(readString(body, offset: &offset), config)
        XCTAssertEqual(offset, body.count)
    }

    private func readLE(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func readBE(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readString(_ data: Data, offset: inout Int) -> String? {
        var length = 0
        var shift = 0
        while true {
            let byte = data[offset]
            offset += 1
            length |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        defer { offset += length }
        return String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8)
    }
}
