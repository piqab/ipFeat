import CryptoKit
import Foundation

private struct EnginePolicy: Decodable {
    var autoInstall = false
    var requestedAt: Date?
}

private struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let digest: String?
    }
    let tag_name: String
    let prerelease: Bool
    let body: String?
    let assets: [Asset]

    var version: String { String(tag_name.dropFirst()) }
}

private struct EngineStatus: Codable {
    var activeVersion: String?
    var lastCheck: Date?
    var lastError: String?
}

private struct EngineHistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let previousVersion: String?
    let version: String
    let releaseChanges: [String]
    let configurationChanges: [String]
    let checksum: String
    let validationOutput: String
    var previousBinaryPath: String?
    var previousSnapshotName: String?
}

private enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

private enum Updater {
    static let base = URL(fileURLWithPath: "/Library/Application Support/ipFeat", isDirectory: true)
    static let engines = base.appendingPathComponent("engines", isDirectory: true)
    static let current = engines.appendingPathComponent("current")
    static let statusURL = base.appendingPathComponent("engine-status.json")
    static let historyURL = base.appendingPathComponent("engine-history.json")
    static let configSnapshotURL = base.appendingPathComponent("engine-active-config.json")
    static let githubAPI = URL(string: "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=100")!

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, arguments[1] == "--config" else {
            throw UpdateError.message("usage: ipFeatUpdater --config FILE --auto-policy FILE | --install-version VERSION | --dry-run-version VERSION | --rollback")
        }
        let config = URL(fileURLWithPath: arguments[2])
        let session = makeSession(config: config)
        defer { session.invalidateAndCancel() }
        let mode = arguments[3]
        guard ["--auto-policy", "--install-version", "--dry-run-version", "--rollback"].contains(mode),
              (mode == "--rollback" ? arguments.count == 4 : arguments.count == 5 || (mode == "--install-version" && arguments.count == 6 && arguments[5] == "--no-restart")) else {
            throw UpdateError.message("Invalid updater arguments")
        }
        guard mode == "--dry-run-version" || getuid() == 0 else {
            throw UpdateError.message("Updater must run as root")
        }
        if isPatchedEngineActive() {
            if mode == "--auto-policy" { return }
            if mode == "--install-version" || mode == "--rollback" {
                throw UpdateError.message("ipFeat patch is active. Remove the patch in ipFeat before switching official sing-box versions.")
            }
        }
        if mode == "--rollback" { try await rollback(config: config); return }
        let auto = mode == "--auto-policy"
        if auto {
            let policyURL = URL(fileURLWithPath: arguments[4])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: policyURL),
                  let policy = try? decoder.decode(EnginePolicy.self, from: data),
                  policy.autoInstall else { return }
            if let lastCheck = readStatus().lastCheck,
               Date().timeIntervalSince(lastCheck) < 86_400,
               (policy.requestedAt ?? .distantPast) <= lastCheck { return }
        }

        do {
            let releases = try await fetchReleases(session: session)
            let selected: Release
            if auto {
                guard let newest = releases.filter({ !$0.prerelease && versionParts($0.version) != nil && hasSupportedAsset($0) })
                    .max(by: { compareVersions($0.version, $1.version) == .orderedAscending }) else {
                    throw UpdateError.message("No stable sing-box release found")
                }
                selected = newest
                if let active = readStatus().activeVersion,
                   compareVersions(active, selected.version) != .orderedAscending {
                    var status = readStatus()
                    status.lastCheck = Date()
                    status.lastError = nil
                    try save(status, at: statusURL)
                    return
                }
            } else {
                let requested = arguments[4]
                guard versionParts(requested) != nil,
                      let release = releases.first(where: { $0.version == requested }) else {
                    throw UpdateError.message("Official sing-box version \(requested) was not found")
                }
                selected = release
            }
            try await install(selected, releases: releases, config: config, session: session,
                              restart: mode != "--dry-run-version" && arguments.count == 5,
                              dryRun: mode == "--dry-run-version")
        } catch {
            if mode != "--dry-run-version" {
                var status = readStatus()
                status.lastCheck = Date()
                status.lastError = error.localizedDescription
                try? save(status, at: statusURL)
            }
            throw error
        }
    }

    private static func isPatchedEngineActive() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: current.path),
              let output = try? execute(current.path, ["version"]) else { return false }
        return output.contains("ipFeat patch: 1.14.4-")
    }

    private static func makeSession(config: URL) -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.waitsForConnectivity = false
        if (try? execute("/sbin/ifconfig", ["utun100"])) != nil,
           let data = try? Data(contentsOf: config),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inbounds = root["inbounds"] as? [[String: Any]] {
            let dedicated = inbounds.first { ($0["tag"] as? String) == "ipfeat-updater" }
            let rules = (root["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
            let proxyInbound = rules.first { ($0["outbound"] as? String) == "proxy" && $0["inbound"] != nil }
                .flatMap { ($0["inbound"] as? [String])?.first }
            let fallback = inbounds.first { ($0["tag"] as? String) == proxyInbound }
            if let port = (dedicated ?? fallback)?["listen_port"] as? Int {
            settings.connectionProxyDictionary = [
                "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port
            ]
            }
        }
        return URLSession(configuration: settings)
    }

    private static func fetchReleases(session: URLSession) async throws -> [Release] {
        var request = URLRequest(url: githubAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ipFeat/1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("GitHub release list is unavailable")
        }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    private static func hasSupportedAsset(_ release: Release) -> Bool {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let name = "sing-box-\(release.version)-darwin-\(architecture).tar.gz"
        return release.assets.contains { $0.name == name && $0.digest?.hasPrefix("sha256:") == true }
    }

    private static func install(_ release: Release, releases: [Release], config: URL, session: URLSession,
                                restart: Bool, dryRun: Bool) async throws {
        let architecture = {
            #if arch(arm64)
            return "arm64"
            #else
            return "amd64"
            #endif
        }()
        let version = release.version
        let assetName = "sing-box-\(version)-darwin-\(architecture).tar.gz"
        guard let digest = release.assets.first(where: { $0.name == assetName })?.digest,
              digest.hasPrefix("sha256:"), digest.count == 71 else {
            throw UpdateError.message("Official SHA-256 digest missing for \(assetName)")
        }
        let expectedHash = String(digest.dropFirst(7)).lowercased()
        guard expectedHash.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.message("Invalid release digest")
        }
        let archiveURL = URL(string: "https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(assetName)")!
        var request = URLRequest(url: archiveURL)
        request.setValue("ipFeat/1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (archive, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("Could not download \(assetName)")
        }
        let actualHash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else { throw UpdateError.message("SHA-256 mismatch for \(assetName)") }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipfeat-engine-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let archiveFile = staging.appendingPathComponent(assetName)
        try archive.write(to: archiveFile, options: .atomic)
        let member = "sing-box-\(version)-darwin-\(architecture)/sing-box"
        let members = try execute("/usr/bin/tar", ["-tzf", archiveFile.path]).split(separator: "\n").map(String.init)
        guard members.contains(member) else { throw UpdateError.message("Release archive has no sing-box binary") }
        let candidate = staging.appendingPathComponent("sing-box")
        let extraction = Process()
        extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extraction.arguments = ["-xOf", archiveFile.path, member]
        FileManager.default.createFile(atPath: candidate.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: candidate)
        extraction.standardOutput = outputFile
        let errors = Pipe()
        extraction.standardError = errors
        try extraction.run()
        extraction.waitUntilExit()
        try outputFile.close()
        guard extraction.terminationStatus == 0 else {
            throw UpdateError.message("Could not extract sing-box: \(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        let reportedVersion = try execute(candidate.path, ["version"])
        guard reportedVersion.hasPrefix("sing-box version \(version)\n") else {
            throw UpdateError.message("Downloaded binary reports an unexpected version")
        }
        let validation = try execute(candidate.path, ["check", "-c", config.path])
        if dryRun {
            print("sing-box \(version): SHA-256 verified; configuration accepted")
            if !validation.isEmpty { print(validation) }
            return
        }

        let oldStatus = readStatus()
        let oldConfig = try? Data(contentsOf: configSnapshotURL)
        let newConfig = try Data(contentsOf: config)
        let changes = configurationDiff(old: oldConfig, new: newConfig)
        let notes = releaseNotes(from: oldStatus.activeVersion, to: version, releases: releases)

        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let versionDir = engines.appendingPathComponent("\(version)-\(actualHash.prefix(12))", isDirectory: true)
        if !FileManager.default.fileExists(atPath: versionDir.path) {
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        }
        let installed = versionDir.appendingPathComponent("sing-box")
        if !FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.copyItem(at: candidate, to: installed)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        } else {
            let existing = try Data(contentsOf: installed)
            let downloaded = try Data(contentsOf: candidate)
            guard SHA256.hash(data: existing) == SHA256.hash(data: downloaded) else {
                throw UpdateError.message("Existing version directory has a different binary")
            }
        }

        let priorTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        var snapshotName: String?
        if let oldConfig {
            let snapshotDirectory = base.appendingPathComponent("engine-snapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let name = "\(UUID().uuidString).json"
            let snapshot = snapshotDirectory.appendingPathComponent(name)
            try oldConfig.write(to: snapshot, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            snapshotName = name
        }
        let newLink = engines.appendingPathComponent("current-new")
        if FileManager.default.fileExists(atPath: newLink.path) { try FileManager.default.removeItem(at: newLink) }
        try FileManager.default.createSymbolicLink(at: newLink, withDestinationURL: installed)
        if rename(newLink.path, current.path) != 0 {
            try? FileManager.default.removeItem(at: newLink)
            throw UpdateError.message("Could not activate version \(version)")
        }

        if restart && FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.ipfeat.network.plist") {
            do {
                let priorPIDs = singBoxPIDs()
                _ = try execute("/bin/launchctl", ["kickstart", "-k", "system/com.ipfeat.network"])
                guard await waitForEngine(after: priorPIDs) else {
                    throw UpdateError.message("sing-box or TUN did not recover after update")
                }
            } catch {
                if let priorTarget {
                    try? FileManager.default.removeItem(at: current)
                    try? FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: priorTarget)
                    _ = try? execute("/bin/launchctl", ["kickstart", "-k", "system/com.ipfeat.network"])
                }
                throw error
            }
        }

        let historyDecoder = JSONDecoder()
        historyDecoder.dateDecodingStrategy = .iso8601
        var history = (try? historyDecoder.decode([EngineHistoryEntry].self, from: Data(contentsOf: historyURL))) ?? []
        history.insert(EngineHistoryEntry(
            date: Date(), previousVersion: oldStatus.activeVersion, version: version,
            releaseChanges: notes, configurationChanges: changes,
            checksum: actualHash, validationOutput: validation,
            previousBinaryPath: priorTarget, previousSnapshotName: snapshotName
        ), at: 0)
        try save(Array(history.prefix(30)), at: historyURL)
        var status = oldStatus
        status.activeVersion = version
        status.lastCheck = Date()
        status.lastError = nil
        try save(status, at: statusURL)
        try newConfig.write(to: configSnapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configSnapshotURL.path)
    }

    private static func rollback(config: URL) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let history = try decoder.decode([EngineHistoryEntry].self, from: Data(contentsOf: historyURL))
        guard let latest = history.first, let previousVersion = latest.previousVersion,
              let previousBinaryPath = latest.previousBinaryPath,
              previousBinaryPath.hasPrefix(engines.path + "/"),
              FileManager.default.isExecutableFile(atPath: previousBinaryPath),
              let snapshotName = latest.previousSnapshotName,
              snapshotName.range(of: #"^[0-9A-Fa-f-]+\.json$"#, options: .regularExpression) != nil else {
            throw UpdateError.message("No previous managed version available for rollback")
        }
        let snapshot = base.appendingPathComponent("engine-snapshots/\(snapshotName)")
        let previousConfig = try Data(contentsOf: snapshot)
        let currentConfig = try Data(contentsOf: config)
        let currentTarget = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        let validation = try execute(previousBinaryPath, ["check", "-c", snapshot.path])
        let oldAttributes = try FileManager.default.attributesOfItem(atPath: config.path)
        let priorUID = oldAttributes[.ownerAccountID] as? NSNumber
        let priorGID = oldAttributes[.groupOwnerAccountID] as? NSNumber
        let temporaryConfig = config.deletingLastPathComponent().appendingPathComponent("sing-box.rollback.json")
        try previousConfig.write(to: temporaryConfig, options: .atomic)
        if let priorUID, let priorGID {
            try FileManager.default.setAttributes([
                .ownerAccountID: priorUID, .groupOwnerAccountID: priorGID,
                .posixPermissions: 0o600
            ], ofItemAtPath: temporaryConfig.path)
        }
        let newLink = engines.appendingPathComponent("current-rollback")
        if FileManager.default.fileExists(atPath: newLink.path) { try FileManager.default.removeItem(at: newLink) }
        try FileManager.default.createSymbolicLink(atPath: newLink.path, withDestinationPath: previousBinaryPath)
        guard rename(newLink.path, current.path) == 0 else {
            throw UpdateError.message("Could not restore previous binary")
        }
        guard rename(temporaryConfig.path, config.path) == 0 else {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: currentTarget)
            throw UpdateError.message("Could not restore previous configuration")
        }
        do {
            let priorPIDs = singBoxPIDs()
            _ = try execute("/bin/launchctl", ["kickstart", "-k", "system/com.ipfeat.network"])
            guard await waitForEngine(after: priorPIDs) else {
                throw UpdateError.message("sing-box or TUN did not recover after rollback")
            }
        } catch {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: currentTarget)
            try? currentConfig.write(to: config, options: .atomic)
            if let priorUID, let priorGID {
                try? FileManager.default.setAttributes([
                    .ownerAccountID: priorUID, .groupOwnerAccountID: priorGID,
                    .posixPermissions: 0o600
                ], ofItemAtPath: config.path)
            }
            _ = try? execute("/bin/launchctl", ["kickstart", "-k", "system/com.ipfeat.network"])
            throw error
        }
        var status = readStatus()
        status.activeVersion = previousVersion
        status.lastCheck = Date()
        status.lastError = nil
        try save(status, at: statusURL)
        try previousConfig.write(to: configSnapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configSnapshotURL.path)
        var updated = history
        updated.insert(EngineHistoryEntry(
            date: Date(), previousVersion: latest.version, version: previousVersion,
            releaseChanges: ["Откат с \(latest.version)"],
            configurationChanges: configurationDiff(old: currentConfig, new: previousConfig),
            checksum: "", validationOutput: validation,
            previousBinaryPath: currentTarget, previousSnapshotName: nil
        ), at: 0)
        try save(Array(updated.prefix(30)), at: historyURL)
    }

    private static func execute(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw UpdateError.message(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }

    private static func singBoxPIDs() -> Set<String> {
        let output = (try? execute("/usr/bin/pgrep", ["-x", "sing-box"])) ?? ""
        return Set(output.split(separator: "\n").map(String.init))
    }

    private static func waitForEngine(after oldPIDs: Set<String>) async -> Bool {
        for _ in 0..<30 {
            let newPIDs = singBoxPIDs().subtracting(oldPIDs)
            if !newPIDs.isEmpty && (try? execute("/sbin/ifconfig", ["utun100"])) != nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !singBoxPIDs().intersection(newPIDs).isEmpty { return true }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private static func readStatus() -> EngineStatus {
        guard let data = try? Data(contentsOf: statusURL) else { return EngineStatus() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(EngineStatus.self, from: data)) ?? EngineStatus()
    }

    private static func save<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    private static func configurationDiff(old: Data?, new: Data) -> [String] {
        guard let old, let oldJSON = try? JSONSerialization.jsonObject(with: old),
              let newJSON = try? JSONSerialization.jsonObject(with: new) else {
            return ["Первый сохранённый снимок конфигурации"]
        }
        let before = flatten(oldJSON)
        let after = flatten(newJSON)
        return Set(before.keys).union(after.keys).sorted().compactMap { key in
            if before[key] == nil { return "Добавлено: \(key)" }
            if after[key] == nil { return "Удалено: \(key)" }
            return before[key] == after[key] ? nil : "Изменено: \(key)"
        }
    }

    private static func flatten(_ value: Any, path: String = "$") -> [String: String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [:]) { result, entry in
                result.merge(flatten(entry.value, path: path + "." + entry.key)) { _, new in new }
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().reduce(into: [:]) { result, entry in
                result.merge(flatten(entry.element, path: path + "[\(entry.offset)]")) { _, new in new }
            }
        }
        return [path: String(describing: value)]
    }

    private static func releaseNotes(from previous: String?, to selected: String, releases: [Release]) -> [String] {
        releases.filter { release in
            guard !release.prerelease || release.version == selected else { return false }
            guard versionParts(release.version) != nil,
                  compareVersions(release.version, selected) != .orderedDescending else { return false }
            guard let previous else { return release.version == selected }
            return compareVersions(release.version, previous) == .orderedDescending
        }
        .sorted { compareVersions($0.version, $1.version) == .orderedAscending }
        .map { "\($0.tag_name)\n\($0.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Изменения не описаны")" }
    }

    private static func versionParts(_ value: String) -> [Int]? {
        guard value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil else { return nil }
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    private static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let left = versionParts(a) ?? [0, 0, 0]
        let right = versionParts(b) ?? [0, 0, 0]
        if left != right {
            return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
        }
        let leftSuffix = a.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
        let rightSuffix = b.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
        if leftSuffix == rightSuffix { return .orderedSame }
        if leftSuffix == nil { return .orderedDescending }
        if rightSuffix == nil { return .orderedAscending }
        return leftSuffix!.compare(rightSuffix!, options: .numeric)
    }
}

@main
private enum Main {
    static func main() async {
        do { try await Updater.run() }
        catch {
            fputs("ipFeatUpdater: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
