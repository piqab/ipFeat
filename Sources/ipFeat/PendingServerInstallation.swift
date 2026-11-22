import CryptoKit
import Foundation
import Darwin

struct PendingServerInstallation: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var serverIPv4: String
    var sshPort: Int
    var architecture: String
    var version: String
    var protocolName: String
    var outboundTag: String
    var clientJSON: String
    var serverJSON: String
    var createdAt: Date

    var configSHA256: String {
        SHA256.hash(data: Data(serverJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var receipt: String {
        "IPFEAT_INSTALL_OK id=\(id.uuidString.lowercased()) version=\(version) sha256=\(configSHA256)"
    }

    func accepts(_ output: String) -> Bool {
        let oldReceipt = receipt.replacingOccurrences(of: "IPFEAT_INSTALL_OK", with: "IPINFORMER_INSTALL_OK")
        return output.components(separatedBy: .newlines).contains {
            [receipt, oldReceipt].contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var assetName: String { "sing-box-\(version)-linux-\(architecture).tar.gz" }
    var remoteFolder: String { "/tmp/ipfeat-manual-\(id.uuidString.lowercased())" }

    func serverScript() throws -> String {
        guard ["amd64", "arm64"].contains(architecture),
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil,
              NewServerConfiguration.isIPv4(serverIPv4) else {
            throw failure("Invalid manual installation metadata")
        }
        let expectedMachine = architecture == "amd64" ? "x86_64" : "aarch64"
        let encoded = Data(serverJSON.utf8).base64EncodedString()
        return """
        #!/usr/bin/env bash
        set -euo pipefail
        umask 077
        if [ "$(id -u)" -ne 0 ]; then echo 'Run this installer as root' >&2; exit 1; fi
        machine=$(uname -m)
        if [ "$machine" != '\(expectedMachine)' ] \(architecture == "arm64" ? "&& [ \"$machine\" != 'arm64' ]" : ""); then
          echo 'Wrong VPS architecture for this installation package' >&2; exit 1
        fi
        command -v sha256sum >/dev/null 2>&1
        folder='\(remoteFolder)'
        mkdir -p "$folder"
        chmod 700 "$folder"
        printf '%s' '\(encoded)' | base64 -d > "$folder/config.json"
        printf '%s  %s\\n' '\(configSHA256)' "$folder/config.json" | sha256sum -c -
        if [ -f /etc/systemd/system/ipfeat-sing-box.service ] &&
           [ -f /etc/ipfeat-sing-box/config.json ] &&
           [ -x /usr/local/lib/ipfeat-sing-box/sing-box ] &&
           [ "$(sha256sum /etc/ipfeat-sing-box/config.json | cut -d ' ' -f 1)" = '\(configSHA256)' ] &&
           [ "$(/usr/local/lib/ipfeat-sing-box/sing-box version | sed -n '1{s/^sing-box version //p;}')" = '\(version)' ] &&
           systemctl is-active --quiet ipfeat-sing-box.service &&
           systemctl is-enabled --quiet ipfeat-sing-box.service; then
          echo '\(receipt)'
          rm -rf "$folder"
          exit 0
        fi
        \(ServerDeployment.deploymentScript(folder: remoteFolder, version: version,
                                            assetName: assetName, cleanupInputFolder: true))
        printf '%s  %s\\n' '\(configSHA256)' /etc/ipfeat-sing-box/config.json | sha256sum -c -
        systemctl is-active --quiet ipfeat-sing-box.service
        systemctl is-enabled --quiet ipfeat-sing-box.service
        echo '\(receipt)'
        """
    }

    func hostScript() throws -> String {
        let encodedScript = Data(try serverScript().utf8).base64EncodedString()
        return """
        #!/usr/bin/env bash
        set -euo pipefail
        umask 077
        target="${1:-root@\(serverIPv4)}"
        port="${2:-\(sshPort)}"
        case "$port" in *[!0-9]*|'') echo 'SSH port must be numeric' >&2; exit 1;; esac
        folder='\(remoteFolder)'
        asset='\(assetName)'
        version='\(version)'
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        python3 - "$work/install-on-server.sh" <<'PY'
        import base64, sys
        with open(sys.argv[1], 'wb') as stream:
            stream.write(base64.b64decode('\(encodedScript)'))
        PY
        chmod 700 "$work/install-on-server.sh"
        curl --ipv4 --fail --silent --show-error --location --retry 2 \\
          -H 'Accept: application/vnd.github+json' -H 'User-Agent: ipFeat/1' \\
          "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$version" -o "$work/release.json"
        python3 - "$work/release.json" "$asset" "$version" > "$work/$asset.sha256" <<'PY'
        import json, re, sys
        with open(sys.argv[1], encoding='utf-8') as stream:
            release = json.load(stream)
        if release.get('tag_name') != 'v' + sys.argv[3]:
            raise SystemExit('GitHub returned another sing-box version')
        assets = [item for item in release.get('assets', []) if item.get('name') == sys.argv[2]]
        if len(assets) != 1:
            raise SystemExit('Linux archive not found in the release')
        digest = assets[0].get('digest', '')
        if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
            raise SystemExit('Missing valid SHA-256 digest')
        print(digest[7:])
        PY
        curl --ipv4 --fail --show-error --location --retry 2 \\
          "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" -o "$work/$asset"
        python3 - "$work/$asset" "$work/$asset.sha256" <<'PY'
        import hashlib, sys
        checksum = hashlib.sha256()
        with open(sys.argv[1], 'rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                checksum.update(block)
        actual = checksum.hexdigest()
        with open(sys.argv[2], encoding='ascii') as stream:
            expected = stream.read().strip().lower()
        if actual != expected:
            raise SystemExit('sing-box archive SHA-256 mismatch')
        PY
        ssh -p "$port" -o StrictHostKeyChecking=accept-new "$target" "umask 077; mkdir -p '$folder'; chmod 700 '$folder'"
        scp -P "$port" -o StrictHostKeyChecking=accept-new \\
          "$work/$asset" "$work/$asset.sha256" "$work/install-on-server.sh" "$target:$folder/"
        ssh -p "$port" -o StrictHostKeyChecking=accept-new "$target" "bash '$folder/install-on-server.sh'"
        """
    }

    func writePackage(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for (name, contents) in [("install-on-server.sh", try serverScript()),
                                 ("install-from-host.sh", try hostScript())] {
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let instructions = """
        Run install-on-server.sh as root on the VPS, or run install-from-host.sh on a Mac/Linux host
        that can SSH to root@\(serverIPv4). The host path downloads and verifies the Linux archive,
        then transfers it to the VPS. Both paths print an IPFEAT_INSTALL_OK line only after
        the service is active and enabled at boot. Paste that line into ipFeat to add the client.
        These scripts contain the server configuration and its credentials. Keep this folder private.
        """
        let readme = directory.appendingPathComponent("README.txt")
        try Data(instructions.utf8).write(to: readme, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readme.path)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ipFeat.PendingServerInstallation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum PendingServerInstallationStore {
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ipFeat/pending-server-installs", isDirectory: true)
    }

    static func save(_ item: PendingServerInstallation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(item.id.uuidString.lowercased() + ".json").path
        let data = try JSONEncoder().encode(item)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func all() -> [PendingServerInstallation] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PendingServerInstallation.self, from: $0) }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func allChecked() throws -> [PendingServerInstallation] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            let item = try JSONDecoder().decode(PendingServerInstallation.self, from: Data(contentsOf: url))
            guard url.deletingPathExtension().lastPathComponent == item.id.uuidString.lowercased() else {
                throw BackupError.incompleteArchive(String(format: AppLanguage.localized("Pending VPS installation file has a mismatched ID: %@"),
                                                           url.lastPathComponent))
            }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func replaceAll(with items: [PendingServerInstallation]) throws {
        let old = try allChecked()
        for item in items { try save(item) }
        let retained = Set(items.map(\.id))
        for item in old where !retained.contains(item.id) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(item.id.uuidString.lowercased() + ".json"))
        }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString.lowercased() + ".json"))
    }
}
