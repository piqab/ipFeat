import Foundation
import zlib

enum ClientQRSError: LocalizedError {
    case missingOutbound
    case invalidData
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .missingOutbound: return "Клиентский outbound не найден в основной конфигурации"
        case .invalidData: return "Не удалось подготовить клиентский профиль"
        case .compressionFailed: return "Не удалось сжать профиль для QRS"
        }
    }
}

/// Format used by sing-box for Android's QRS scanner and libbox profile import.
enum ClientQRS {
    static let prefix = "https://qrss.netlify.app/#"
    static let sliceSize = 500

    static func androidConfiguration(connection: ClientConnection, mainJSON: String) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: Data(mainJSON.utf8)) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              let outbound = outbounds.first(where: { $0["tag"] as? String == connection.outboundTag }),
              outbound["type"] as? String == connection.protocolName else {
            throw ClientQRSError.missingOutbound
        }
        let config: [String: Any] = [
            "log": ["level": "info"],
            "dns": ["strategy": "ipv4_only"],
            "inbounds": [["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true]],
            "outbounds": [outbound],
            "route": ["final": connection.outboundTag, "auto_detect_interface": true]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else { throw ClientQRSError.invalidData }
        return json
    }

    static func profileData(name: String, config: String) throws -> Data {
        var payload = Data()
        appendString(name, to: &payload)
        appendInt32(0, to: &payload, littleEndian: false) // ProfileTypeLocal
        appendString(config, to: &payload)
        let zlibData = try compress(payload)
        guard zlibData.count >= 6 else { throw ClientQRSError.compressionFailed }
        var gzip = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        gzip.append(zlibData.dropFirst(2).dropLast(4))
        appendInt32(crc32Value(payload), to: &gzip, littleEndian: true)
        appendInt32(UInt32(truncatingIfNeeded: payload.count), to: &gzip, littleEndian: true)
        var result = Data([3, 1]) // MessageTypeProfileContent, format version 1
        result.append(gzip)
        return result
    }

    static func frames(profileData: Data) throws -> [String] {
        guard profileData.count <= 5_000_000 else { throw ClientQRSError.invalidData }
        let metadata = Data(#"{"filename":"IPInformer.bpf","contentType":"application/octet-stream"}"#.utf8)
        var file = Data()
        appendInt32(UInt32(metadata.count), to: &file, littleEndian: false)
        file.append(metadata)
        appendInt32(UInt32(profileData.count), to: &file, littleEndian: false)
        file.append(profileData)

        let compressed = try compress(file)
        let count = (compressed.count + sliceSize - 1) / sliceSize
        guard count > 0, count <= 10_000 else { throw ClientQRSError.invalidData }
        let checksum = crc32Value(file) ^ UInt32(count)
        var slices: [[UInt8]] = []
        let bytes = [UInt8](compressed)
        for index in 0..<count {
            let start = index * sliceSize
            let end = min(start + sliceSize, bytes.count)
            var slice = Array(bytes[start..<end])
            slice += repeatElement(0, count: sliceSize - slice.count)
            slices.append(slice)
        }

        func frame(indices: [Int], slice: [UInt8]) -> String {
            var payload = Data()
            appendInt32(UInt32(indices.count), to: &payload, littleEndian: true)
            for index in indices { appendInt32(UInt32(index), to: &payload, littleEndian: true) }
            appendInt32(UInt32(count), to: &payload, littleEndian: true)
            appendInt32(UInt32(compressed.count), to: &payload, littleEndian: true)
            appendInt32(checksum, to: &payload, littleEndian: true)
            payload.append(contentsOf: slice)
            return prefix + payload.base64EncodedString()
        }

        // Systematic frames guarantee completion after a full cycle. Adjacent XOR
        // frames let SFA's fountain decoder recover one missed slice sooner.
        var result = (0..<count).map { frame(indices: [$0], slice: slices[$0]) }
        if count > 1 {
            for index in 0..<count {
                let next = (index + 1) % count
                let parity = zip(slices[index], slices[next]).map { $0 ^ $1 }
                result.append(frame(indices: [index, next], slice: parity))
            }
        }
        return result
    }

    private static func compress(_ data: Data) throws -> Data {
        var capacity = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(capacity))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &capacity,
                          input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw ClientQRSError.compressionFailed }
        return Data(output.prefix(Int(capacity)))
    }

    private static func crc32Value(_ data: Data) -> UInt32 {
        UInt32(truncatingIfNeeded: data.withUnsafeBytes {
            crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))
        })
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = bytes.count
        while length >= 0x80 {
            data.append(UInt8(length & 0x7f) | 0x80)
            length >>= 7
        }
        data.append(UInt8(length))
        data.append(bytes)
    }

    private static func appendInt32(_ value: UInt32, to data: inout Data, littleEndian: Bool) {
        let number = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: number) { data.append(contentsOf: $0) }
    }
}
