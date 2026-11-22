import Foundation
import Darwin

enum ServerSSHAuthentication: Sendable {
    case key(String)
    case rootPassword(String)
}

struct ServerSSHSettings: Sendable {
    let host: String
    let user: String
    let port: Int
    let authentication: ServerSSHAuthentication
}

enum ServerDeployment {
    typealias Log = @Sendable (String) -> Void

    struct VerificationReport: Sendable {
        let hostName: String
        let architecture: String
        let configFound: Bool
        let unitFound: Bool
        let binaryFound: Bool
        let hashMatches: Bool
        let versionMatches: Bool
        let active: Bool
        let enabled: Bool
        let legacyService: Bool
        let output: String

        var isInstalled: Bool {
            configFound && unitFound && binaryFound && hashMatches && versionMatches && active && enabled
        }

        var summary: String {
            if isInstalled {
                let verified = String(format: AppLanguage.localized("Verified on %@: configuration, sing-box and systemd service are ready"), hostName)
                return legacyService ? verified + " · previous IP Informer service" : verified
            }
            var problems: [String] = []
            if !configFound { problems.append(AppLanguage.localized("configuration missing")) }
            else if !hashMatches { problems.append(AppLanguage.localized("configuration hash differs")) }
            if !unitFound { problems.append(AppLanguage.localized("systemd unit missing")) }
            if !binaryFound { problems.append(AppLanguage.localized("sing-box binary missing")) }
            else if !versionMatches { problems.append(AppLanguage.localized("sing-box version differs")) }
            if !active { problems.append(AppLanguage.localized("service not active")) }
            if !enabled { problems.append(AppLanguage.localized("service not enabled at boot")) }
            return String(format: AppLanguage.localized("Verification failed on %@: %@"),
                          hostName, problems.joined(separator: ", "))
        }
    }

    static func deploy(configuration: String, version: String, access: ServerSSHSettings,
                       log: Log? = nil) throws -> String {
        let (target, options) = try sshAccess(access)
        let ssh = ["-p", String(access.port)] + options + [target]
        let probe = """
        printf 'IPFEAT_OS=%s\\n' "$(uname -s)";
        printf 'IPFEAT_ARCH=%s\\n' "$(uname -m)";
        printf 'IPFEAT_SYSTEMCTL=%s\\n' "$(command -v systemctl || true)";
        printf 'IPFEAT_INIT=%s\\n' "$(ps -p 1 -o comm= 2>/dev/null || true)"
        """
        log?("$ ssh -p \(access.port) \(target) '<проверка ОС, архитектуры и systemd>'\n")
        let platform = try run("/usr/bin/ssh", ssh + [probe], authentication: access.authentication, log: log)
        let architecture = try parsePlatform(platform)
        log?("Платформа принята: Linux \(architecture)\n")
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil else {
            throw error("Некорректный номер версии sing-box")
        }
        let assetName = "sing-box-\(version)-linux-\(architecture).tar.gz"
        log?("Выпуск sing-box: \(version), архив \(assetName); VPS получит SHA-256 с GitHub и проверит архив\n")

        let folder = "/tmp/ipfeat-new-\(UUID().uuidString.lowercased())"
        let localConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipfeat-server-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: localConfig) }
        let configFD = open(localConfig.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard configFD >= 0 else { throw error("Не удалось создать временный файл конфигурации") }
        let configFile = FileHandle(fileDescriptor: configFD, closeOnDealloc: true)
        try configFile.write(contentsOf: Data(configuration.utf8))
        try configFile.close()
        log?("$ ssh -p \(access.port) \(target) 'umask 077; mkdir \(folder)'\n")
        _ = try run("/usr/bin/ssh", ssh + ["umask 077; mkdir \(folder)"], authentication: access.authentication, log: log)
        defer {
            log?("$ ssh -p \(access.port) \(target) 'rm -rf \(folder)'\n")
            _ = try? run("/usr/bin/ssh", ssh + ["rm -rf \(folder)"], authentication: access.authentication, log: log)
        }
        let scp = ["-P", String(access.port)] + options + [localConfig.path, "\(target):\(folder)/config.json"]
        log?("$ scp -P \(access.port) <серверный JSON> \(target):\(folder)/config.json\n")
        _ = try run("/usr/bin/scp", scp, authentication: access.authentication, log: log)
        let script = deploymentScript(folder: folder, version: version, assetName: assetName)
        let privilege = access.user == "root" ? "/bin/bash -s" : "sudo -n /bin/bash -s"
        log?("$ ssh -p \(access.port) \(target) '\(privilege)' < <сценарий установки>\n")
        let result = try run("/usr/bin/ssh", ssh + [privilege], input: Data(script.utf8),
                             authentication: access.authentication, log: log)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func installedMatches(version: String, configSHA256: String, access: ServerSSHSettings,
                                 log: Log? = nil) throws -> Bool {
        try verify(version: version, configSHA256: configSHA256, access: access, log: log).isInstalled
    }

    static func verify(version: String, configSHA256: String, access: ServerSSHSettings,
                       log: Log? = nil) throws -> VerificationReport {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil,
              configSHA256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw error("Invalid sing-box version or configuration hash")
        }
        let (target, options) = try sshAccess(access)
        let privilege = access.user == "root" ? "/bin/bash -s" : "sudo -n /bin/bash -s"
        let check = """
        set -u
        printf 'IPFEAT_VERIFY_BEGIN=1\\n'
        printf 'IPFEAT_VERIFY_HOST=%s\\n' "$(hostname)"
        printf 'IPFEAT_VERIFY_ARCH=%s\\n' "$(uname -m)"
        brand=ipfeat
        if [ ! -f /etc/systemd/system/ipfeat-sing-box.service ] &&
           [ -f /etc/systemd/system/ipinformer-sing-box.service ]; then brand=ipinformer; fi
        unit_path="/etc/systemd/system/$brand-sing-box.service"
        config_path="/etc/$brand-sing-box/config.json"
        binary_path="/usr/local/lib/$brand-sing-box/sing-box"
        [ -f "$config_path" ] && config=1 || config=0
        [ -f "$unit_path" ] && unit=1 || unit=0
        [ -x "$binary_path" ] && binary=1 || binary=0
        actual_hash=$(sha256sum "$config_path" 2>/dev/null | cut -d ' ' -f 1)
        actual_version=$("$binary_path" version 2>/dev/null | sed -n '1{s/^sing-box version //p;}')
        systemctl is-active --quiet "$brand-sing-box.service" 2>/dev/null && active=1 || active=0
        systemctl is-enabled --quiet "$brand-sing-box.service" 2>/dev/null && enabled=1 || enabled=0
        printf 'IPFEAT_VERIFY_BRAND=%s\\n' "$brand"
        printf 'IPFEAT_VERIFY_CONFIG=%s\\n' "$config"
        printf 'IPFEAT_VERIFY_UNIT=%s\\n' "$unit"
        printf 'IPFEAT_VERIFY_BINARY=%s\\n' "$binary"
        printf 'IPFEAT_VERIFY_HASH=%s\\n' "$actual_hash"
        printf 'IPFEAT_VERIFY_VERSION=%s\\n' "$actual_version"
        printf 'IPFEAT_VERIFY_ACTIVE=%s\\n' "$active"
        printf 'IPFEAT_VERIFY_ENABLED=%s\\n' "$enabled"
        printf 'IPFEAT_VERIFY_END=1\\n'
        printf '\\n--- systemctl status ---\\n'
        systemctl status "$brand-sing-box.service" --no-pager --full 2>&1 || true
        printf '\\n--- journalctl (last 40 lines) ---\\n'
        journalctl -u "$brand-sing-box.service" -n 40 --no-pager 2>&1 || true
        """
        log?("$ ssh -p \(access.port) \(target) '<independent service verification and journal>'\n")
        let output = try run("/usr/bin/ssh", ["-p", String(access.port)] + options + [target, privilege],
                             input: Data(check.utf8), authentication: access.authentication, log: log)
        return try parseVerification(output, version: version, configSHA256: configSHA256)
    }

    static func parseVerification(_ output: String, version: String,
                                  configSHA256: String) throws -> VerificationReport {
        guard let begin = output.range(of: "IPFEAT_VERIFY_BEGIN=1\n"),
              let end = output.range(of: "IPFEAT_VERIFY_END=1\n", range: begin.upperBound..<output.endIndex) else {
            throw error("SSH verification returned no complete result. \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let lines = output[begin.upperBound..<end.lowerBound].components(separatedBy: .newlines)
        func value(_ key: String) -> String? {
            lines.first(where: { $0.hasPrefix("IPFEAT_VERIFY_\(key)=") })
                .map { String($0.dropFirst("IPFEAT_VERIFY_\(key)=".count)) }
        }
        guard let host = value("HOST"), !host.isEmpty, let arch = value("ARCH"),
              let config = value("CONFIG"), let unit = value("UNIT"),
              let binary = value("BINARY"), let hash = value("HASH"),
              let actualVersion = value("VERSION"), let active = value("ACTIVE"),
              let enabled = value("ENABLED"),
              [config, unit, binary, active, enabled].allSatisfy({ $0 == "0" || $0 == "1" }) else {
            throw error("SSH verification returned incomplete service checks")
        }
        return VerificationReport(hostName: host, architecture: arch,
            configFound: config == "1", unitFound: unit == "1", binaryFound: binary == "1",
            hashMatches: hash.caseInsensitiveCompare(configSHA256) == .orderedSame,
            versionMatches: actualVersion == version, active: active == "1", enabled: enabled == "1",
            legacyService: value("BRAND") == "ipinformer",
            output: output)
    }

    private static func sshAccess(_ access: ServerSSHSettings) throws -> (String, [String]) {
        guard NewServerConfiguration.isIPv4(access.host),
              (1...65535).contains(access.port),
              access.user.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
            throw error("Проверьте IPv4, SSH-пользователя и порт")
        }
        let common: [String]
        switch access.authentication {
        case .key(let path):
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw error("SSH-ключ недоступен для чтения")
            }
            common = ["-i", path, "-o", "BatchMode=yes"]
        case .rootPassword(let password):
            guard access.user == "root", !password.isEmpty,
                  !password.contains("\n"), !password.contains("\r"), password.utf8.count <= 4096 else {
                throw error("Укажите пароль SSH-пользователя root")
            }
            common = ["-F", "/dev/null", "-o", "BatchMode=no",
                      "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
                      "-o", "KbdInteractiveAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }
        let target = "\(access.user)@\(access.host)"
        let options = common + ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
        return (target, options)
    }

    static func uninstall(access: ServerSSHSettings, log: Log? = nil) throws -> String {
        let (target, options) = try sshAccess(access)
        let ssh = ["-p", String(access.port)] + options + [target]
        let privilege = access.user == "root" ? "/bin/bash -s" : "sudo -n /bin/bash -s"
        log?("$ ssh -p \(access.port) \(target) '\(privilege)' < <сценарий удаления ipFeat>\n")
        return try run("/usr/bin/ssh", ssh + [privilege], input: Data(uninstallScript().utf8),
                       authentication: access.authentication, log: log).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uninstallScript() -> String {
        """
        set -euo pipefail
        set -x
        brand=ipfeat
        if [ ! -f /etc/systemd/system/ipfeat-sing-box.service ] &&
           [ -f /etc/systemd/system/ipinformer-sing-box.service ]; then brand=ipinformer; fi
        unit="/etc/systemd/system/$brand-sing-box.service"
        binary="/usr/local/lib/$brand-sing-box/sing-box"
        config="/etc/$brand-sing-box/config.json"
        if [ ! -f "$unit" ] || [ -L "$unit" ]; then
          echo 'Служба ipFeat не найдена; удаление на VPS отменено' >&2
          exit 1
        fi
        grep -Fqx "ExecStart=$binary run -c $config" "$unit" || {
          echo 'Служба отличается от установленной ipFeat; удаление отменено' >&2
          exit 1
        }
        migrated=false
        if [ "$brand" = ipfeat ] && [ -f /etc/ipfeat-sing-box/.migrated-from-ipinformer ]; then
          migrated=true
        fi
        systemctl disable --now "$brand-sing-box.service"
        if systemctl is-active --quiet "$brand-sing-box.service"; then
          echo 'Служба всё ещё активна; удаление файлов отменено' >&2
          exit 1
        fi
        rm -rf "/etc/$brand-sing-box" "/usr/local/lib/$brand-sing-box"
        rm -f "$unit"
        if [ "$migrated" = true ] && [ ! -e /etc/systemd/system/ipinformer-sing-box.service ]; then
          rm -rf /etc/ipinformer-sing-box /usr/local/lib/ipinformer-sing-box
        fi
        systemctl daemon-reload
        echo 'Служба и файлы ipFeat удалены с VPS'
        """
    }

    static func migrateLegacy(version: String, configSHA256: String, access: ServerSSHSettings,
                              log: Log? = nil) throws -> String {
        let report = try verify(version: version, configSHA256: configSHA256, access: access, log: log)
        guard report.isInstalled, report.legacyService else {
            throw error("A verified previous IP Informer service was not found on this VPS")
        }
        let (target, options) = try sshAccess(access)
        let privilege = access.user == "root" ? "/bin/bash -s" : "sudo -n /bin/bash -s"
        let script = legacyMigrationScript(version: version, configSHA256: configSHA256)
        log?("$ ssh -p \(access.port) \(target) '<migrate previous server service to ipFeat>'\n")
        return try run("/usr/bin/ssh", ["-p", String(access.port)] + options + [target, privilege],
                       input: Data(script.utf8), authentication: access.authentication, log: log)
    }

    static func legacyMigrationScript(version: String, configSHA256: String) -> String {
        """
        set -euo pipefail
        old_unit=/etc/systemd/system/ipinformer-sing-box.service
        new_unit=/etc/systemd/system/ipfeat-sing-box.service
        old_config=/etc/ipinformer-sing-box/config.json
        old_binary=/usr/local/lib/ipinformer-sing-box/sing-box
        new_config=/etc/ipfeat-sing-box/config.json
        new_binary=/usr/local/lib/ipfeat-sing-box/sing-box
        [ -f "$old_unit" ] && [ ! -L "$old_unit" ]
        grep -Fqx "ExecStart=$old_binary run -c $old_config" "$old_unit"
        [ -f "$old_config" ] && [ -x "$old_binary" ]
        [ "$(sha256sum "$old_config" | cut -d ' ' -f 1)" = '\(configSHA256)' ]
        [ "$("$old_binary" version | sed -n '1{s/^sing-box version //p;}')" = '\(version)' ]
        systemctl is-active --quiet ipinformer-sing-box.service
        systemctl is-enabled --quiet ipinformer-sing-box.service
        [ ! -e "$new_unit" ] && [ ! -e /etc/ipfeat-sing-box ] && [ ! -e /usr/local/lib/ipfeat-sing-box ]
        if ! cp -a /etc/ipinformer-sing-box /etc/ipfeat-sing-box ||
           ! cp -a /usr/local/lib/ipinformer-sing-box /usr/local/lib/ipfeat-sing-box ||
           ! sed -e 's/ipinformer/ipfeat/g' -e 's/IP Informer/ipFeat/g' "$old_unit" > "$new_unit" ||
           ! printf '%s\n' 'ipFeat migration backup' > /etc/ipfeat-sing-box/.migrated-from-ipinformer; then
          rm -rf /etc/ipfeat-sing-box /usr/local/lib/ipfeat-sing-box "$new_unit"
          exit 1
        fi
        if ! grep -Fqx "ExecStart=$new_binary run -c $new_config" "$new_unit" ||
           ! "$new_binary" check -c "$new_config"; then
          rm -f "$new_unit"
          rm -rf /etc/ipfeat-sing-box /usr/local/lib/ipfeat-sing-box
          exit 1
        fi
        systemctl daemon-reload
        if ! systemctl disable --now ipinformer-sing-box.service; then
          rm -f "$new_unit"
          rm -rf /etc/ipfeat-sing-box /usr/local/lib/ipfeat-sing-box
          systemctl daemon-reload
          exit 1
        fi
        if ! systemctl enable --now ipfeat-sing-box.service ||
           ! systemctl is-active --quiet ipfeat-sing-box.service ||
           ! systemctl is-enabled --quiet ipfeat-sing-box.service; then
          systemctl disable --now ipfeat-sing-box.service >/dev/null 2>&1 || true
          rm -f "$new_unit"
          rm -rf /etc/ipfeat-sing-box /usr/local/lib/ipfeat-sing-box
          systemctl daemon-reload
          systemctl enable --now ipinformer-sing-box.service
          echo 'ipFeat service failed; previous service restored' >&2
          exit 1
        fi
        rm -f "$old_unit"
        systemctl daemon-reload
        echo 'IPFEAT_MIGRATED=1'
        """
    }

    static func parsePlatform(_ output: String) throws -> String {
        let lines = output.components(separatedBy: .newlines)
        func value(_ key: String) -> String? {
            let marker = "IPFEAT_\(key)="
            return lines.reversed().compactMap { line in
                guard let range = line.range(of: marker) else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            }.first
        }
        guard let os = value("OS"), let arch = value("ARCH"), let systemctl = value("SYSTEMCTL") else {
            throw error("Не удалось прочитать ответ SSH о платформе. Вывод: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard os == "Linux" else { throw error("На сервере обнаружена ОС \(os), требуется Linux") }
        guard !systemctl.isEmpty else {
            throw error("На сервере Linux (\(arch)), но команда systemctl не найдена. Инициализация: \(value("INIT") ?? "неизвестно")")
        }
        switch arch {
        case "x86_64": return "amd64"
        case "aarch64", "arm64": return "arm64"
        default: throw error("Архитектура \(arch) пока не поддерживается установщиком")
        }
    }

    static func deploymentScript(folder: String, version: String, assetName: String,
                                 cleanupInputFolder: Bool = false) -> String {
        let member = "sing-box-\(version)-linux-\(assetName.contains("arm64") ? "arm64" : "amd64")/sing-box"
        return """
        set -euo pipefail
        set -x
        if [ -e /etc/ipfeat-sing-box ] || [ -e /usr/local/lib/ipfeat-sing-box ] || [ -e /etc/systemd/system/ipfeat-sing-box.service ] ||
           [ -e /etc/ipinformer-sing-box ] || [ -e /usr/local/lib/ipinformer-sing-box ] || [ -e /etc/systemd/system/ipinformer-sing-box.service ]; then
          echo 'ipFeat server already exists; refusing to overwrite it' >&2
          exit 1
        fi
        work=$(mktemp -d)
        created=0
        cleanup() { rm -rf "$work"; \(cleanupInputFolder ? "rm -rf '\(folder)';" : "") }
        rollback() {
          if [ "$created" = 1 ]; then
            systemctl disable --now ipfeat-sing-box.service >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/ipfeat-sing-box.service
            rm -rf /etc/ipfeat-sing-box /usr/local/lib/ipfeat-sing-box
            systemctl daemon-reload || true
          fi
        }
        trap cleanup EXIT
        trap rollback ERR
        cp '\(folder)/config.json' "$work/config.json"
        chmod 600 "$work/config.json"
        command -v sha256sum >/dev/null 2>&1
        command -v tar >/dev/null 2>&1
        if [ -f '\(folder)/\(assetName)' ] && [ -f '\(folder)/\(assetName).sha256' ]; then
          hash=$(cat '\(folder)/\(assetName).sha256')
          cp '\(folder)/\(assetName)' "$work/\(assetName)"
          echo 'Using verified archive transferred from another host'
        else
          if ! command -v curl >/dev/null 2>&1 || {
            ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1;
          }; then
            if command -v apt-get >/dev/null 2>&1; then
              apt-get update
              DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ca-certificates
            elif command -v dnf >/dev/null 2>&1; then
              dnf install -y curl jq ca-certificates
            elif command -v yum >/dev/null 2>&1; then
              yum install -y curl jq ca-certificates
            elif command -v zypper >/dev/null 2>&1; then
              zypper --non-interactive install curl jq ca-certificates
            else
              echo 'curl and either python3 or jq are required to verify the sing-box release' >&2
              exit 1
            fi
          fi
          curl --ipv4 --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 40 \\
            --header 'Accept: application/vnd.github+json' --header 'User-Agent: ipFeat/1' \\
            'https://api.github.com/repos/SagerNet/sing-box/releases/tags/v\(version)' \\
            --output "$work/release.json"
          if command -v python3 >/dev/null 2>&1; then
            digest=$(python3 - "$work/release.json" 'v\(version)' '\(assetName)' <<'PY'
        import json
        import sys
        with open(sys.argv[1], encoding="utf-8") as stream:
            release = json.load(stream)
        if release.get("tag_name") != sys.argv[2]:
            raise SystemExit("GitHub returned a different sing-box release")
        assets = [asset for asset in release.get("assets", []) if asset.get("name") == sys.argv[3]]
        if len(assets) != 1:
            raise SystemExit("The sing-box release has no matching Linux archive")
        print(assets[0].get("digest", ""))
        PY
            )
          else
            digest=$(jq -er --arg tag 'v\(version)' --arg asset '\(assetName)' \\
              'if .tag_name != $tag then error("GitHub returned a different release")
               else (.assets // [] | map(select(.name == $asset)) |
                 if length == 1 then .[0].digest else error("Linux archive not found") end) end' \\
              "$work/release.json")
          fi
          if [[ ! "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
            echo 'GitHub did not provide a valid SHA-256 digest for the Linux archive' >&2
            exit 1
          fi
          hash=${digest#sha256:}
          curl --ipv4 --fail --location --retry 2 --connect-timeout 10 --max-time 120 \\
            'https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(assetName)' \\
            --output "$work/\(assetName)"
        fi
        if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
          echo 'Invalid SHA-256 for sing-box archive' >&2
          exit 1
        fi
        printf '%s  %s\\n' "$hash" "$work/\(assetName)" | sha256sum -c -
        tar -xzf "$work/\(assetName)" -C "$work" '\(member)'
        "$work/\(member)" check -c "$work/config.json"
        created=1
        install -d -m 755 /usr/local/lib/ipfeat-sing-box /etc/ipfeat-sing-box
        install -d -m 700 /etc/ipfeat-sing-box/acme
        install -m 755 "$work/\(member)" /usr/local/lib/ipfeat-sing-box/sing-box
        install -m 600 "$work/config.json" /etc/ipfeat-sing-box/config.json
        test -x /usr/local/lib/ipfeat-sing-box/sing-box
        actual_version=$(/usr/local/lib/ipfeat-sing-box/sing-box version | sed -n '1{s/^sing-box version //p;}')
        test "$actual_version" = '\(version)'
        /usr/local/lib/ipfeat-sing-box/sing-box check -c /etc/ipfeat-sing-box/config.json
        cat > /etc/systemd/system/ipfeat-sing-box.service <<'UNIT'
        [Unit]
        Description=ipFeat sing-box server
        After=network-online.target
        Wants=network-online.target

        [Service]
        ExecStart=/usr/local/lib/ipfeat-sing-box/sing-box run -c /etc/ipfeat-sing-box/config.json
        Restart=on-failure
        RestartSec=3
        User=root
        NoNewPrivileges=true

        [Install]
        WantedBy=multi-user.target
        UNIT
        systemctl daemon-reload
        systemctl enable --now ipfeat-sing-box.service
        sleep 2
        systemctl is-active --quiet ipfeat-sing-box.service
        systemctl is-enabled --quiet ipfeat-sing-box.service
        trap - ERR
        echo 'sing-box server \(version) is active and enabled at boot. Check that the VPS firewall permits the configured service port.'
        """
    }

    static func run(_ path: String, _ arguments: [String], input: Data? = nil,
                    authentication: ServerSSHAuthentication, log: Log? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        var passwordPipe: String?
        var passwordDirectory: URL?
        var passwordWriter: DispatchSemaphore?
        defer { if let passwordDirectory { try? FileManager.default.removeItem(at: passwordDirectory) } }
        if case .rootPassword = authentication {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipfeat-askpass-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            passwordDirectory = directory
            let helper = directory.appendingPathComponent("askpass.sh")
            try Data("#!/bin/sh\nexec /bin/cat \"$IPFEAT_ASKPASS_FIFO\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let fifo = directory.appendingPathComponent("password.fifo").path
            guard mkfifo(fifo, 0o600) == 0 else { throw error("Не удалось создать защищённый канал для SSH-пароля") }
            passwordPipe = fifo
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = helper.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["IPFEAT_ASKPASS_FIFO"] = fifo
            process.environment = environment
            let finished = DispatchSemaphore(value: 0)
            passwordWriter = finished
            // The password stays in memory. The FIFO path and helper contain no secret.
        }
        let stdin: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdin = pipe
        } else {
            stdin = nil
        }
        try process.run()
        if let passwordPipe, case .rootPassword(let password) = authentication, let passwordWriter {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { passwordWriter.signal() }
                let bytes = Array((password + "\n").utf8)
                while process.isRunning {
                    let fd = open(passwordPipe, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 {
                        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                        _ = fcntl(fd, F_SETFL, 0)
                        bytes.withUnsafeBytes { buffer in
                            guard let address = buffer.baseAddress else { return }
                            var offset = 0
                            while offset < buffer.count {
                                let written = Darwin.write(fd, address.advanced(by: offset), buffer.count - offset)
                                if written <= 0 { break }
                                offset += written
                            }
                        }
                        close(fd)
                        return
                    }
                    if errno != ENXIO { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        if let input, let stdin {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            log?(String(decoding: chunk, as: UTF8.self))
        }
        process.waitUntilExit()
        if let passwordWriter { _ = passwordWriter.wait(timeout: .now() + 2) }
        log?("[код завершения: \(process.terminationStatus)]\n")
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if case .rootPassword = authentication, text.contains("Permission denied") {
                throw error("SSH отклонил пароль root. Проверьте пароль и разрешён ли на VPS вход root по паролю. \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            throw error(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ipFeat.ServerDeployment", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
