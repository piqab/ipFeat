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
    }

    private struct PendingPrompt {
        let request: Request
        let deadline: DispatchTime
        let complete: (String) -> Void
    }

    private let store: RoutingStore
    private let path: String
    private let queue = DispatchQueue(label: "local.ipinformer.child-route")
    private var pendingPrompts: [PendingPrompt] = []
    private var isShowingPrompt = false
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
            // Each connection has its own deadline. An open alert must not
            // block accepting and reading the next request from sing-box.
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
        try? FileManager.default.removeItem(atPath: path)
    }

    nonisolated private func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
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
        let deadline = DispatchTime.now() + .seconds(18)
        let semaphore = DispatchSemaphore(value: 0)
        var route = ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { semaphore.signal(); return }
            self.pendingPrompts.append(PendingPrompt(request: request, deadline: deadline) { selected in
                route = selected
                semaphore.signal()
            })
            self.showNextPrompt()
        }
        guard semaphore.wait(timeout: deadline) == .success else { return }
        guard let data = try? JSONEncoder().encode(Reply(id: request.id, route: route)) else { return }
        var reply = data
        reply.append(0x0a)
        _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private func showNextPrompt() {
        guard !isShowingPrompt else { return }
        isShowingPrompt = true
        defer { isShowingPrompt = false }
        while !pendingPrompts.isEmpty {
            let pending = pendingPrompts.removeFirst()
            let route = DispatchTime.now() < pending.deadline
                ? chooseRoute(for: pending.request, deadline: pending.deadline) : ""
            pending.complete(route)
        }
    }

    private func chooseRoute(for request: Request, deadline: DispatchTime) -> String {
        let now = DispatchTime.now()
        guard now < deadline else { return "" }
        guard !request.command_path.isEmpty else { return "" }
        let isUnknown = request.kind == "unknown"
        let appID = request.application_id.flatMap(UUID.init(uuidString:))
        let application = appID.flatMap { id in
            store.configuration.applications.first(where: {
                $0.id == id && $0.enabled && $0.askChildCommands
            })
        }
        guard isUnknown ? store.configuration.askUnknownProcesses : application != nil else { return "" }
        let processName = URL(fileURLWithPath: request.command_path).lastPathComponent
        let parentName = request.parent_path.map { URL(fileURLWithPath: $0).lastPathComponent }
        let alert = NSAlert()
        alert.messageText = isUnknown ? "Route for an unlisted process" : "Child command route"
        alert.informativeText = isUnknown
            ? "\(processName) opened a public IPv4 connection. Choose a route for this run.\n\(request.command_path)"
            : "\(processName) opened a public IPv4 connection from \(application?.name ?? request.application_name ?? "an application")\(parentName.map { " through \($0)" } ?? ""). Choose its route."
        let options = store.outboundTags.map { (label: $0, route: DefaultRoute.outbound($0)) }
            + (isUnknown
                ? [(label: "Block public internet", route: DefaultRoute.block)]
                : [(label: "No network", route: DefaultRoute.block),
                   (label: "This Mac only", route: DefaultRoute.localOnly)])
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        options.forEach { picker.addItem(withTitle: $0.label) }
        alert.accessoryView = picker
        alert.addButton(withTitle: isUnknown ? "Use for this run" : "Remember route")
        alert.addButton(withTitle: isUnknown ? "Use default route" : "Use application route")
        NSApp.activate(ignoringOtherApps: true)
        let beforeDisplay = DispatchTime.now()
        guard beforeDisplay < deadline else { return "" }
        let remaining = Double(deadline.uptimeNanoseconds - beforeDisplay.uptimeNanoseconds) / 1_000_000_000
        let expiry = Timer(timeInterval: remaining, repeats: false) { [weak alert] _ in
            guard let alert, NSApp.modalWindow === alert.window else { return }
            NSApp.abortModal()
        }
        RunLoop.main.add(expiry, forMode: .modalPanel)
        let response = alert.runModal()
        expiry.invalidate()
        alert.window.orderOut(nil)
        guard response == .alertFirstButtonReturn,
              DispatchTime.now() < deadline,
              options.indices.contains(picker.indexOfSelectedItem) else { return "" }
        let selected = options[picker.indexOfSelectedItem].route
        if !isUnknown, let appID {
            store.saveChildCommandChoice(applicationID: appID, executablePath: request.command_path, route: selected)
        }
        switch selected {
        case .outbound(let tag): return tag
        case .localOnly, .block: return "reject"
        }
    }
}
