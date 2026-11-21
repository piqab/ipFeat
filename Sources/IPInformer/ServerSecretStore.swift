import Foundation
import Security

enum ServerSecretStore {
    private static let service = "local.ipinformer.server-config"

    static func save(_ configuration: String, id: UUID) throws {
        let account = id.uuidString
        let data = Data(configuration.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            let inserted = SecItemAdd(addition as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(id: UUID) -> String? {
        try? loadChecked(id: id)
    }

    static func loadChecked(id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else {
            throw NSError(domain: "IPInformer.ServerSecretStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppLanguage.localized("Server JSON in Keychain is not data")])
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "IPInformer.ServerSecretStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: AppLanguage.localized("Server JSON in Keychain is not UTF-8")])
        }
        return json
    }

    static func allRequired(for connections: [ClientConnection]) throws -> [String: String] {
        var result: [String: String] = [:]
        for connection in connections {
            guard let json = try loadChecked(id: connection.id) else {
                throw BackupError.incompleteArchive(String(format: AppLanguage.localized("Server JSON is missing from Keychain for %@"),
                                                           connection.name))
            }
            result[connection.id.uuidString] = json
        }
        return result
    }

    static func all(for connections: [ClientConnection]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: connections.compactMap { item in
            load(id: item.id).map { (item.id.uuidString, $0) }
        })
    }

    static func delete(id: UUID) {
        try? deleteChecked(id: id)
    }

    static func deleteChecked(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
