import CommonCrypto
import CryptoKit
import Foundation

struct ConfigurationBackup: Codable {
    var version = 3
    var routing: RoutingConfiguration
    var sources: [IPSource]? = nil
    var checkInterval: Double? = nil
    var widgetsVisible: Bool? = nil
    var widgetOffsets: [String: String]? = nil
    var launchAtLogin: Bool
    var configurationHistory: [ConfigurationRevision]
    var engineAutoInstall: Bool? = nil
    var serverConfigurations: [String: String]? = nil
    var processAISettings: ProcessAISettingsSnapshot? = nil
    var preferredAppLanguage: String? = nil
    var pendingServerInstallations: [PendingServerInstallation]? = nil
}

private struct EncryptedBackup: Codable {
    var format = "IPInformerEncryptedBackup"
    var version = 1
    var salt: Data
    var sealedData: Data
}

enum BackupError: LocalizedError {
    case passwordRequired
    case weakPassword
    case invalidArchive
    case unsupportedVersion
    case wrongPasswordOrCorrupt
    case keyDerivationFailed
    case incompleteArchive(String)

    var errorDescription: String? {
        switch self {
        case .passwordRequired: return AppLanguage.localized("Введите пароль архива")
        case .weakPassword: return AppLanguage.localized("Пароль должен содержать не менее 8 символов")
        case .invalidArchive: return AppLanguage.localized("Файл не является архивом IP Informer")
        case .unsupportedVersion: return AppLanguage.localized("Версия архива не поддерживается")
        case .wrongPasswordOrCorrupt: return AppLanguage.localized("Неверный пароль или архив повреждён")
        case .keyDerivationFailed: return AppLanguage.localized("Не удалось создать ключ шифрования")
        case .incompleteArchive(let detail): return detail
        }
    }
}

enum ConfigurationArchive {
    private static let iterations: UInt32 = 210_000

    static func encrypt(_ backup: ConfigurationBackup, password: String) throws -> Data {
        guard !password.isEmpty else { throw BackupError.passwordRequired }
        guard password.count >= 8 else { throw BackupError.weakPassword }
        var payload = backup
        if payload.version >= 3 {
            payload.sources = nil
            payload.checkInterval = nil
            payload.widgetsVisible = nil
            payload.widgetOffsets = nil
        }
        try validateContents(payload)
        var random = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let key = try deriveKey(password: password, salt: salt)
        let plaintext = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw BackupError.invalidArchive }
        return try JSONEncoder().encode(EncryptedBackup(salt: salt, sealedData: combined))
    }

    static func decrypt(_ data: Data, password: String) throws -> ConfigurationBackup {
        guard !password.isEmpty else { throw BackupError.passwordRequired }
        guard let envelope = try? JSONDecoder().decode(EncryptedBackup.self, from: data),
              envelope.format == "IPInformerEncryptedBackup", envelope.salt.count == 16 else {
            throw BackupError.invalidArchive
        }
        guard envelope.version == 1 else { throw BackupError.unsupportedVersion }
        let key = try deriveKey(password: password, salt: envelope.salt)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealedData),
              let plaintext = try? AES.GCM.open(box, using: key),
              let backup = try? JSONDecoder().decode(ConfigurationBackup.self, from: plaintext) else {
            throw BackupError.wrongPasswordOrCorrupt
        }
        guard (1...3).contains(backup.version) else { throw BackupError.unsupportedVersion }
        try validateContents(backup)
        return backup
    }

    static func validateContents(_ backup: ConfigurationBackup) throws {
        guard (1...3).contains(backup.version) else { throw BackupError.unsupportedVersion }
        guard backup.version >= 2 else { return }
        let secrets = backup.serverConfigurations ?? [:]
        for connection in backup.routing.clientConnections where secrets[connection.id.uuidString] == nil {
            throw BackupError.incompleteArchive(String(format: AppLanguage.localized("Missing server JSON for %@ (%@)"),
                                                       connection.name, connection.id.uuidString))
        }
        let pending = backup.pendingServerInstallations ?? []
        let pendingIDs = pending.map(\.id)
        guard Set(pendingIDs).count == pendingIDs.count,
              Set(pendingIDs).isDisjoint(with: Set(backup.routing.clientConnections.map(\.id))) else {
            throw BackupError.incompleteArchive(AppLanguage.localized("Pending VPS installations conflict with saved connections"))
        }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBuffer in
                bytes.withUnsafeMutableBufferPointer { keyBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, password.utf8.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        keyBuffer.baseAddress, keyBuffer.count
                    )
                }
            }
        }
        guard result == kCCSuccess else { throw BackupError.keyDerivationFailed }
        return SymmetricKey(data: bytes)
    }
}

enum ConfigurationDiff {
    struct Line: Identifiable {
        let id: Int
        let marker: Character
        let text: String
    }

    static func lines(old: String, new: String) -> [Line] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let changes = after.difference(from: before)
        let removed = Set(changes.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let inserted = Set(changes.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if removed.contains(oldIndex), oldIndex < before.count {
                result.append(Line(id: result.count, marker: "-", text: before[oldIndex]))
                oldIndex += 1
            } else if inserted.contains(newIndex), newIndex < after.count {
                result.append(Line(id: result.count, marker: "+", text: after[newIndex]))
                newIndex += 1
            } else if oldIndex < before.count, newIndex < after.count {
                result.append(Line(id: result.count, marker: " ", text: after[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else { break }
        }
        return result
    }
}
