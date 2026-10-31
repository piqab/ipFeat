import Foundation

struct IPSource: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: String
    var isEnabled: Bool
    let isBuiltIn: Bool

    static let defaults: [IPSource] = [
        IPSource(
            id: UUID(uuidString: "D40B942C-7A02-4DFC-9230-1D89B18DA101")!,
            name: "ipify",
            url: "https://api.ipify.org?format=json",
            isEnabled: true,
            isBuiltIn: true
        ),
        IPSource(
            id: UUID(uuidString: "D40B942C-7A02-4DFC-9230-1D89B18DA102")!,
            name: "icanhazip",
            url: "https://ipv4.icanhazip.com",
            isEnabled: true,
            isBuiltIn: true
        ),
        IPSource(
            id: UUID(uuidString: "D40B942C-7A02-4DFC-9230-1D89B18DA103")!,
            name: "Cloudflare",
            url: "https://1.1.1.1/cdn-cgi/trace",
            isEnabled: true,
            isBuiltIn: true
        )
    ]
}
