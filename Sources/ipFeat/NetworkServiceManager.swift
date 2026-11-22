import Foundation

struct NetworkServiceSnapshot: Sendable {
    var networkInstalled = false
    var networkLoaded = false
    var supervisorPID: Int?
    var managedEnginePID: Int?
    var updaterInstalled = false
    var updaterLoaded = false
    var tunnelReady = false
    var configurationPath: String?
    var externalEngines: [String] = []

    var networkHealthy: Bool { networkLoaded && supervisorPID != nil && managedEnginePID != nil && tunnelReady }
}

@MainActor
final class NetworkServiceManager: ObservableObject {
    @Published private(set) var snapshot = NetworkServiceSnapshot()
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var log = ""

    func refresh() async {
        snapshot = await Task.detached(priority: .utility) { Self.inspect() }.value
    }

    func install() async { await operate(script: "install-network-service.sh") }
    func remove() async { await operate(script: "uninstall-network-service.sh") }

    func restart() async {
        guard !busy else { return }
        busy = true
        let result = await Task.detached(priority: .userInitiated) {
            Self.runPrivileged("/bin/launchctl kickstart -k system/com.ipfeat.network")
        }.value
        message = result.output.isEmpty ? (result.success ? "Network service restarted" : "Restart failed") : result.output
        await refresh()
        busy = false
    }

    func loadLog() async {
        log = await Task.detached(priority: .utility) {
            let result = Self.run("/usr/bin/tail", ["-n", "120", "/Library/Logs/ipFeat/network.log"])
            return result.output
        }.value
    }

    private func operate(script: String) async {
        guard !busy else { return }
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("scripts/\(script)").path,
              FileManager.default.isExecutableFile(atPath: path) else {
            message = "Service installer is missing from the application bundle"
            return
        }
        busy = true
        let result = await Task.detached(priority: .userInitiated) {
            Self.runPrivileged("/bin/zsh \(Self.shellQuote(path))")
        }.value
        message = result.output.isEmpty ? (result.success ? "Service operation completed" : "Service operation failed") : result.output
        await refresh()
        busy = false
    }

    private nonisolated static func inspect() -> NetworkServiceSnapshot {
        var result = NetworkServiceSnapshot()
        let networkPlist = "/Library/LaunchDaemons/com.ipfeat.network.plist"
        let updaterPlist = "/Library/LaunchDaemons/com.ipfeat.updater.plist"
        result.networkInstalled = FileManager.default.fileExists(atPath: networkPlist)
        result.updaterInstalled = FileManager.default.fileExists(atPath: updaterPlist)
        var managedBinaryPath: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: networkPlist)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let arguments = plist["ProgramArguments"] as? [String], arguments.count > 2 {
            managedBinaryPath = arguments[1]
            result.configurationPath = arguments[2]
        }
        let network = run("/bin/launchctl", ["print", "system/com.ipfeat.network"])
        result.networkLoaded = network.success
        result.supervisorPID = launchdPID(network.output)
        result.updaterLoaded = run("/bin/launchctl", ["print", "system/com.ipfeat.updater"]).success
        result.tunnelReady = run("/sbin/ifconfig", ["utun100"]).success

        if let supervisorPID = result.supervisorPID, let managedBinaryPath {
            let children = run("/usr/bin/pgrep", ["-P", String(supervisorPID)])
            for pidLine in children.output.split(separator: "\n") {
                guard let pid = Int(pidLine.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                let details = run("/bin/ps", ["-p", String(pid), "-o", "ppid=", "-o", "command="])
                guard let parsed = processDetails(details.output), parsed.parent == supervisorPID,
                      isManagedEngineCommand(parsed.command, expectedPath: managedBinaryPath) else { continue }
                result.managedEnginePID = pid
                break
            }
        }

        let processes = run("/usr/bin/pgrep", ["-x", "sing-box"])
        for pidLine in processes.output.split(separator: "\n") {
            guard let pid = Int(pidLine.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if pid == result.managedEnginePID { continue }
            let details = run("/bin/ps", ["-p", String(pid), "-o", "ppid=", "-o", "command="])
            guard let parsed = processDetails(details.output) else { continue }
            result.externalEngines.append("PID \(pid) · \(parsed.command)")
        }
        return result
    }

    private nonisolated static func processDetails(_ output: String) -> (parent: Int, command: String)? {
        let words = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard words.count == 2, let parent = Int(words[0]) else { return nil }
        return (parent, String(words[1]))
    }

    nonisolated static func isManagedEngineCommand(_ command: String, expectedPath: String) -> Bool {
        command == expectedPath + " run" || command.hasPrefix(expectedPath + " run ")
    }

    private nonisolated static func launchdPID(_ output: String) -> Int? {
        guard let match = output.range(of: #"(?m)^\s*pid = ([0-9]+)\s*$"#, options: .regularExpression) else { return nil }
        return Int(output[match].split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private nonisolated static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func runPrivileged(_ command: String) -> (success: Bool, output: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            return (process.terminationStatus == 0, output)
        } catch { return (false, error.localizedDescription) }
    }
}
