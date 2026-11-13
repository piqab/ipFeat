import AppKit
import Darwin
import Foundation

/// Receives a bounded, local request from the patched sing-box process.
@MainActor
final class ChildRoutePromptServer {
    private struct Request: Decodable {
        let id: String
        let application_id: String
        let application_name: String
        let command_path: String
    }

    private struct Reply: Encodable {
        let id: String
        let route: String
    }

    private let store: RoutingStore
    private let path: String
    private let queue = DispatchQueue(label: "local.ipinformer.child-route")
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
            self?.queue.async { [weak self] in self?.handle(client) }
        }
        readSource.setCancelHandler { Darwin.close(fd) }
        source = readSource
        readSource.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    nonisolated private func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
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
        var route = ""
        DispatchQueue.main.async { [weak self] in
            route = self?.chooseRoute(for: request) ?? ""
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 7) == .success else { return }
        guard let data = try? JSONEncoder().encode(Reply(id: request.id, route: route)) else { return }
        var reply = data
        reply.append(0x0a)
        _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private func chooseRoute(for request: Request) -> String {
        guard let appID = UUID(uuidString: request.application_id),
              let application = store.configuration.applications.first(where: {
                  $0.id == appID && $0.enabled && $0.askChildCommands
              }),
              !request.command_path.isEmpty else { return "" }
        let alert = NSAlert()
        alert.messageText = "Маршрут дочерней команды"
        alert.informativeText = "\(application.name) запустила \(URL(fileURLWithPath: request.command_path).lastPathComponent). Выберите маршрут для внешних IPv4-соединений этой команды."
        let options = store.outboundTags.map { (label: $0, route: DefaultRoute.outbound($0)) }
            + [(label: "Без сети", route: DefaultRoute.block),
               (label: "Только этот Mac", route: DefaultRoute.localOnly)]
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        options.forEach { picker.addItem(withTitle: $0.label) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Запомнить маршрут")
        alert.addButton(withTitle: "По маршруту программы")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              options.indices.contains(picker.indexOfSelectedItem) else { return "" }
        let selected = options[picker.indexOfSelectedItem].route
        store.saveChildCommandChoice(applicationID: appID, executablePath: request.command_path, route: selected)
        switch selected {
        case .outbound(let tag): return tag
        case .localOnly, .block: return "reject"
        }
    }
}
