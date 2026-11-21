import Foundation

// Retained only to decode IP checker records in version 1 and 2 backups.
struct IPSource: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: String
    var isEnabled: Bool
    let isBuiltIn: Bool
}
