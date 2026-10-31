import Foundation
import SystemConfiguration

enum NetworkInterfaceProvider {
    static func connectedIPv4Networks() -> [LocalIPv4Network] {
        var result = Set<LocalIPv4Network>()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  name != "lo0", !name.hasPrefix("utun"),
                  let address = interface.ifa_addr,
                  let netmask = interface.ifa_netmask,
                  address.pointee.sa_family == AF_INET,
                  netmask.pointee.sa_family == AF_INET else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard let network = LocalIPv4Network(interface: name, address: ip, mask: mask) else { continue }
            result.insert(network)
        }
        return result.sorted {
            if $0.prefixLength != $1.prefixLength { return $0.prefixLength > $1.prefixLength }
            if $0.networkAddress != $1.networkAddress { return $0.networkAddress < $1.networkAddress }
            return $0.interface < $1.interface
        }
    }

    static func availableInterfaces() -> [NetworkInterfaceOption] {
        var friendlyNames: [String: String] = [:]
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                let displayName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsdName
                friendlyNames[bsdName] = displayName
            }
        }

        var addressMap: [String: [String]] = [:]
        var upMap: [String: Bool] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            upMap[name] = (flags & IFF_UP) != 0

            guard let address = interface.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(address, length, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: hostname).components(separatedBy: "%").first ?? ""
                if !value.isEmpty { addressMap[name, default: []].append(value) }
            }
        }

        return Set(addressMap.keys).union(friendlyNames.keys)
            .filter { $0 != "lo0" && !$0.hasPrefix("ipinformer") }
            .map { name in
                NetworkInterfaceOption(
                    name: name,
                    displayName: friendlyNames[name] ?? inferredName(for: name),
                    addresses: Array(Set(addressMap[name] ?? [])).sorted(),
                    isUp: upMap[name] ?? false
                )
            }
            .sorted {
                if $0.isUp != $1.isUp { return $0.isUp && !$1.isUp }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func inferredName(for name: String) -> String {
        if name.hasPrefix("utun") { return "VPN" }
        if name.hasPrefix("en") { return "Сетевой интерфейс" }
        if name.hasPrefix("bridge") { return "Мост" }
        return "Интерфейс"
    }
}

struct LocalIPv4Network: Hashable, Sendable {
    let interface: String
    let networkAddress: UInt32
    let prefixLength: Int

    init?(interface: String, address: UInt32, mask: UInt32) {
        let prefix = mask.nonzeroBitCount
        guard (1...32).contains(prefix), mask == UInt32.max << (32 - prefix),
              address & 0xff00_0000 != 0x7f00_0000,
              address != 0 else { return nil }
        self.interface = interface
        networkAddress = address & mask
        prefixLength = prefix
        let allowed = (prefix >= 8 && networkAddress & 0xff00_0000 == 0x0a00_0000)
            || (prefix >= 12 && networkAddress & 0xfff0_0000 == 0xac10_0000)
            || (prefix >= 16 && networkAddress & 0xffff_0000 == 0xc0a8_0000)
            || (prefix >= 16 && networkAddress & 0xffff_0000 == 0xa9fe_0000)
        guard allowed else { return nil }
    }

    var cidr: String {
        let address = (0...3).reversed().map { String((networkAddress >> ($0 * 8)) & 0xff) }.joined(separator: ".")
        return "\(address)/\(prefixLength)"
    }

    var outboundTag: String {
        "ipinformer-lan-" + interface
    }

    func contains(_ address: UInt32) -> Bool {
        let mask = UInt32.max << (32 - prefixLength)
        return address & mask == networkAddress
    }
}
