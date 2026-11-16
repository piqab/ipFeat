import AppKit
import Darwin
import Foundation

/// Receives a bounded, local request from the patched sing-box process.
@MainActor
final class ChildRoutePromptServer {
    private struct Request: Decodable {
        let id: String
        let kind: String?
        let application_id: String?
        let application_name: String?
        let command_path: String
        let parent_path: String?
    }

    private struct Reply: Encodable {
        let id: String
        let route: String
        let use_default: Bool
    }

    private let store: RoutingStore
    private let path: String
    private let queue = DispatchQueue(label: "local.ipinformer.child-route")
    private var activePanels: [UUID: RoutePromptPanel] = [:]
    private var source: DispatchSourceRead?

    init(store: RoutingStore) {
        self.store = store
        self.path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IPInformer/child-route.sock").path
    }

    func start() {
        guard source == nil, path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           attributes[.type] as? FileAttributeType == .typeSocket {
            try? FileManager.default.removeItem(atPath: path)
        }
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return
        }
        _ = Darwin.chmod(path, 0o600)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard Darwin.getpeereid(client, &peerUID, &peerGID) == 0,
                  peerUID == 0 || peerUID == Darwin.getuid() else {
                Darwin.close(client)
                return
            }
            // A route panel may stay open indefinitely. Accept each client
            // independently so one decision cannot delay another prompt.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
            }
        }
        readSource.setCancelHandler { Darwin.close(fd) }
        source = readSource
        readSource.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        for panel in Array(activePanels.values) { panel.dismiss() }
        try? FileManager.default.removeItem(atPath: path)
    }

    nonisolated private func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var noSIGPIPE: Int32 = 1
        _ = withUnsafePointer(to: &noSIGPIPE) { pointer in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while input.count < 4096 {
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard readCount > 0 else { return }
            input.append(contentsOf: buffer.prefix(readCount))
            if input.contains(0x0a) { break }
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: input) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var route = "reject"
        DispatchQueue.main.async { [weak self] in
            guard let self else { semaphore.signal(); return }
            self.presentPrompt(request) { selected in
                route = selected
                semaphore.signal()
            }
        }
        semaphore.wait()
        let useDefault = route == "\u{0}policy"
        guard let data = try? JSONEncoder().encode(Reply(id: request.id, route: useDefault ? "" : route,
                                                         use_default: useDefault)) else { return }
        var reply = data
        reply.append(0x0a)
        _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private func presentPrompt(_ request: Request, complete: @escaping (String) -> Void) {
        guard !request.command_path.isEmpty else { complete("reject"); return }
        let isUnknown = request.kind == "unknown"
        let appID = request.application_id.flatMap(UUID.init(uuidString:))
        let application = appID.flatMap { id in
            store.configuration.applications.first(where: {
                $0.id == id && $0.enabled && $0.askChildCommands
            })
        }
        guard isUnknown ? store.configuration.askUnknownProcesses : application != nil else {
            complete("reject")
            return
        }
        let processName = URL(fileURLWithPath: request.command_path).lastPathComponent
        let parentName = request.parent_path.map { URL(fileURLWithPath: $0).lastPathComponent }
        let title = isUnknown ? "Route for an unlisted process" : "Child command route"
        let detail = isUnknown
            ? "\(processName) opened a public IPv4 connection. Choose a route for this run."
            : "\(processName) opened a public IPv4 connection from \(application?.name ?? request.application_name ?? "an application")\(parentName.map { " through \($0)" } ?? ""). Choose its route."
        let options = store.outboundTags.map { RoutePromptOption(label: $0, route: .outbound($0)) }
            + (isUnknown
                ? [RoutePromptOption(label: "Block public internet", route: .block)]
                : [RoutePromptOption(label: "No network", route: .block),
                   RoutePromptOption(label: "This Mac only", route: .localOnly)])
        let id = UUID()
        let panel = RoutePromptPanel(
            title: title, detail: detail, processPath: request.command_path,
            parentPath: request.parent_path, applicationName: application?.name ?? request.application_name,
            isUnknown: isUnknown, options: options, offset: activePanels.count
        ) { [weak self] decision in
            guard let self else { complete("reject"); return }
            if case .selected(let selected) = decision, !isUnknown, let appID {
                self.store.saveChildCommandChoice(applicationID: appID,
                                                   executablePath: request.command_path, route: selected)
            }
            self.activePanels.removeValue(forKey: id)
            complete(Self.routeString(for: decision))
        }
        activePanels[id] = panel
        panel.show()
    }

    private static func routeString(for decision: RoutePromptDecision) -> String {
        switch decision {
        case .ordinaryPolicy: return "\u{0}policy"
        case .blocked: return "reject"
        case .selected(let route):
            switch route {
            case .outbound(let tag): return tag
            case .localOnly, .block: return "reject"
            }
        }
    }
}
