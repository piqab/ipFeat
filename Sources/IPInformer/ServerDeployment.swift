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

    static func deploy(configuration: String, release: EngineRelease, access: ServerSSHSettings,
                       log: Log? = nil) throws -> String {
        let (target, options) = try sshAccess(access)
        let ssh = ["-p", String(access.port)] + options + [target]
        let probe = """
        printf 'IPINFORMER_OS=%s\\n' "$(uname -s)";
        printf 'IPINFORMER_ARCH=%s\\n' "$(uname -m)";
        printf 'IPINFORMER_SYSTEMCTL=%s\\n' "$(command -v systemctl || true)";
        printf 'IPINFORMER_INIT=%s\\n' "$(ps -p 1 -o comm= 2>/dev/null || true)"
        """
        log?("$ ssh -p \(access.port) \(target) '<проверка ОС, архитектуры и systemd>'\n")
        let platform = try run("/usr/bin/ssh", ssh + [probe], authentication: access.authentication, log: log)
        let architecture = try parsePlatform(platform)
        log?("Платформа принята: Linux \(architecture)\n")
        let version = release.version
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil else {
            throw error("Некорректный номер версии sing-box")
        }
        let assetName = "sing-box-\(version)-linux-\(architecture).tar.gz"
        guard let digest = release.assets.first(where: { $0.name == assetName })?.digest,
              digest.hasPrefix("sha256:"), digest.count == 71 else {
            throw error("У выпуска нет проверяемого архива \(assetName)")
        }
        let hash = String(digest.dropFirst(7))
        guard hash.allSatisfy(\.isHexDigit) else { throw error("Некорректная контрольная сумма") }
        log?("Выпуск sing-box: \(version), архив \(assetName), SHA-256 сверяется перед установкой\n")

        let folder = "/tmp/ipinformer-new-\(UUID().uuidString.lowercased())"
        let localConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipinformer-server-\(UUID().uuidString).json")
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
        let script = deploymentScript(folder: folder, version: version, assetName: assetName, sha256: hash)
        let privilege = access.user == "root" ? "/bin/bash -s" : "sudo -n /bin/bash -s"
        log?("$ ssh -p \(access.port) \(target) '\(privilege)' < <сценарий установки>\n")
        let result = try run("/usr/bin/ssh", ssh + [privilege], input: Data(script.utf8),
                             authentication: access.authentication, log: log)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
        log?("$ ssh -p \(access.port) \(target) '\(privilege)' < <сценарий удаления IP Informer>\n")
        return try run("/usr/bin/ssh", ssh + [privilege], input: Data(uninstallScript().utf8),
                       authentication: access.authentication, log: log).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uninstallScript() -> String {
        """
        set -euo pipefail
        set -x
        unit=/etc/systemd/system/ipinformer-sing-box.service
        if [ ! -f "$unit" ] || [ -L "$unit" ]; then
          echo 'Служба IP Informer не найдена; удаление на VPS отменено' >&2
          exit 1
        fi
        grep -Fqx 'ExecStart=/usr/local/lib/ipinformer-sing-box/sing-box run -c /etc/ipinformer-sing-box/config.json' "$unit" || {
          echo 'Служба отличается от установленной IP Informer; удаление отменено' >&2
          exit 1
        }
        systemctl disable --now ipinformer-sing-box.service
        if systemctl is-active --quiet ipinformer-sing-box.service; then
          echo 'Служба всё ещё активна; удаление файлов отменено' >&2
          exit 1
        fi
        rm -rf /etc/ipinformer-sing-box /usr/local/lib/ipinformer-sing-box
        rm -f "$unit"
        systemctl daemon-reload
        echo 'Служба и файлы IP Informer удалены с VPS'
        """
    }

    static func parsePlatform(_ output: String) throws -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(_ key: String) -> String? {
            lines.last(where: { $0.hasPrefix("IPINFORMER_\(key)=") })
                .map { String($0.dropFirst("IPINFORMER_\(key)=".count)) }
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

    static func deploymentScript(folder: String, version: String,
                                 assetName: String, sha256: String) -> String {
        let member = "sing-box-\(version)-linux-\(assetName.contains("arm64") ? "arm64" : "amd64")/sing-box"
        return """
        set -euo pipefail
        set -x
        if [ -e /etc/ipinformer-sing-box ] || [ -e /usr/local/lib/ipinformer-sing-box ] || [ -e /etc/systemd/system/ipinformer-sing-box.service ]; then
          echo 'IP Informer server already exists; refusing to overwrite it' >&2
          exit 1
        fi
        work=$(mktemp -d)
        created=0
        cleanup() { rm -rf "$work"; }
        rollback() {
          if [ "$created" = 1 ]; then
            systemctl disable --now ipinformer-sing-box.service >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/ipinformer-sing-box.service
            rm -rf /etc/ipinformer-sing-box /usr/local/lib/ipinformer-sing-box
            systemctl daemon-reload || true
          fi
        }
        trap cleanup EXIT
        trap rollback ERR
        cp '\(folder)/config.json' "$work/config.json"
        chmod 600 "$work/config.json"
        curl --fail --location --retry 2 --connect-timeout 10 --max-time 120 \\
          'https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(assetName)' \\
          --output "$work/\(assetName)"
        printf '%s  %s\\n' '\(sha256)' "$work/\(assetName)" | sha256sum -c -
        tar -xzf "$work/\(assetName)" -C "$work" '\(member)'
        "$work/\(member)" check -c "$work/config.json"
        created=1
        install -d -m 755 /usr/local/lib/ipinformer-sing-box /etc/ipinformer-sing-box
        install -d -m 700 /etc/ipinformer-sing-box/acme
        install -m 755 "$work/\(member)" /usr/local/lib/ipinformer-sing-box/sing-box
        install -m 600 "$work/config.json" /etc/ipinformer-sing-box/config.json
        test -x /usr/local/lib/ipinformer-sing-box/sing-box
        actual_version=$(/usr/local/lib/ipinformer-sing-box/sing-box version | sed -n '1{s/^sing-box version //p;}')
        test "$actual_version" = '\(version)'
        /usr/local/lib/ipinformer-sing-box/sing-box check -c /etc/ipinformer-sing-box/config.json
        cat > /etc/systemd/system/ipinformer-sing-box.service <<'UNIT'
        [Unit]
        Description=IP Informer sing-box server
        After=network-online.target
        Wants=network-online.target

        [Service]
        ExecStart=/usr/local/lib/ipinformer-sing-box/sing-box run -c /etc/ipinformer-sing-box/config.json
        Restart=on-failure
        RestartSec=3
        User=root
        NoNewPrivileges=true

        [Install]
        WantedBy=multi-user.target
        UNIT
        systemctl daemon-reload
        systemctl enable --now ipinformer-sing-box.service
        sleep 2
        systemctl is-active --quiet ipinformer-sing-box.service
        trap - ERR
        echo 'sing-box server \(version) is active. Check that the VPS firewall permits the configured service port.'
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
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipinformer-askpass-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            passwordDirectory = directory
            let helper = directory.appendingPathComponent("askpass.sh")
            try Data("#!/bin/sh\nexec /bin/cat \"$IPINFORMER_ASKPASS_FIFO\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let fifo = directory.appendingPathComponent("password.fifo").path
            guard mkfifo(fifo, 0o600) == 0 else { throw error("Не удалось создать защищённый канал для SSH-пароля") }
            passwordPipe = fifo
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = helper.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["IPINFORMER_ASKPASS_FIFO"] = fifo
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
        NSError(domain: "IPInformer.ServerDeployment", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
