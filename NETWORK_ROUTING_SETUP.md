# Application routing with sing-box

IP Informer owns one system TUN, normally `utun100`, and routes traffic according to an app, group, command or default profile. It generates the working sing-box configuration from saved client connections and its built-in direct, DNS and TUN settings. Existing base JSON stays active during migration; the app extracts each saved server outbound and shows a diff before replacing the legacy document. Unavailable route assignments can be reassigned individually or together during migration. Generated configuration snapshots can be compared in the sing-box tab.

## Profiles, apps and commands

The **Profiles** tab includes one profile for each outbound tag and built-in **No network**, **This Mac only** and **Local network** profiles. The **Applications** tab assigns a route to each group or ungrouped app. A group route takes priority over an app's saved personal route; moving the app to the ungrouped row restores its personal route. A disabled app is covered by the default route. IP Informer registers itself with `proxy` if that outbound exists. Helpers inside an app bundle follow the app rule; external helpers may require their own rule.

**Default route** applies to every other app, including disabled and unregistered ones. It can use any outbound tag, allow only localhost, or block public access. Managed default rules precede imported general rules. Localhost remains accessible in restricted modes. All ordinary traffic traverses the managed TUN; IP Informer does not silently bypass it.

Each app can permit direct local IPv4 access even while its public traffic uses a proxy or is blocked. Connected private subnets use the matching physical interface. Other private IPv4 uses a direct system route. The built-in **Local network** profile allows localhost, RFC1918, link-local and mDNS/Bonjour but rejects public destinations. Local network interface changes are checked locally about every 10 seconds. IPv6 is intercepted and rejected; DNS strategy is IPv4 only.

Global **Domain routes** match exact hostnames (`blabla.eu`) or subdomains (`*.blabla.eu`) across programs. `*.com` maps to sing-box `domain_suffix: [".com"]`; `*.blabla.eu` maps to `.blabla.eu`, excluding the apex name. More specific patterns win. Local network allowances and explicit app blocks precede domain routes; domain routes precede ordinary child, command, app and default routes. A hostname must be available from DNS mapping or protocol sniffing; direct IP connections cannot match a domain. The same standard sing-box domain rules are embedded in Client JSON and QRS along with required outbounds. On Android, `direct` means the device's own network. Imported QRS profiles do not update automatically when rules change on the Mac.

The **Terminal commands** section assigns a route to an exact executable path such as `/usr/bin/ssh`, `/usr/bin/curl` or `/usr/bin/nc`. This applies from any terminal. Local IPv4 access can be allowed per command, while public IPv4 follows its assigned outbound. An explicit child command choice takes priority over a global command rule, which takes priority over the app or group route. For `ssh` with `ProxyCommand`, the helper that owns the socket is routed separately.

With local patch `1.14.4-6`, newly added apps enable **Ask for a route for child commands** by default. The first public IPv4 connection from an unknown child command asks for a route, which is saved for that app and executable path. A verified parent chain attributes iTerm2 shells through `/usr/bin/login`; it does not inherit through `sudo`. A popup names the socket owner and immediate parent. If `brew` invokes `git`, the socket owner may be `git`.

An optional **Ask for a route for unlisted processes** toggle under Default route also covers apps, commands and user background processes absent from the IP Informer list. It asks on the first public IPv4 connection of each process launch. The answer lasts for that process instance. Local IPv4 connections do not wait. If the popup is unavailable, the eligible public connection is blocked. The listener accepts new requests even while another popup is open. Details: [SING_BOX_PATCH.md](SING_BOX_PATCH.md).
The popup remains open until you choose. The first public connection waits up to 20 seconds; on timeout it is blocked, and a later choice applies to the process's subsequent connections. The **AI** tab configures local and cloud models for the `?` help button, which explains the process without choosing a route. Only process paths and the registered app name are sent when clicked. Keys are stored in Keychain and included in the password-encrypted archive.

The WebKit profile selector routes the shared `com.apple.WebKit.Networking` process through the selected outbound, local-only, local-network or blocked profile before the default route; **Follow normal rules** adds no WebKit rule. More specific child, command and saved-process rules still take precedence. Embedded pages from several apps may share this process.

## Live rules and connection stability

With the patch active, IP Informer keeps a stable `sing-box-base.json` and a separate `sing-box-policy.json`. Adding, removing or moving apps rewrites only policy; sing-box reloads it without restarting TUN. Established flows retain their outbound, and new flows use the new rules. Changing base DNS, TUN or outbounds still restarts the service. An unpatched engine uses compatible `sing-box.json` and restarts on rule changes. One multi-app selection generates one update.

The patch is bundled with the app, checked by SHA-256 and `sing-box check`, then installed with macOS administrator authorization. Earlier revisions can be upgraded to revision 6, preserving the official binary for rollback. Automatic updates to unrelated official versions are disabled while the patch is active. The local patch is never installed on a VPS.

## New server and clients

The **sing-box → Client connections → New server** wizard creates a client/server pair for a new Linux VPS with systemd and public IPv4. It supports `x86_64` and `aarch64`/`arm64`; the VPS needs `/bin/bash`, `curl`, `tar`, `sha256sum` and working `systemctl`. Debian 13 is supported when these are present. The wizard uses the Mac's selected sing-box version and pins it to the generated configs.

Automatic pairs are available for VLESS + Reality, Shadowsocks 2022, VMess, Trojan, Hysteria2 and AnyTLS. TLS protocols can use ACME or embedded PEM certificate and private key. Other compatible inbound/outbound pairs can be edited manually. Both JSON files are checked before deployment. The installation log shows commands, remote output and exit status but omits the SSH password. The official Linux sing-box archive is checked by SHA-256, installed executable, validated, and launched as `ipinformer-sing-box`. After every automatic deployment attempt, IP Informer opens a separate SSH session and checks that the config, binary and unit files exist, the exact server JSON hash and sing-box version match, and the systemd service is active and enabled. It retries this check briefly because systemd startup may lag. Only a successful independent check registers the client as verified. A failed check leaves the installation pending, including both scripts, even when the installer printed a success line. The log shows the verification output, systemctl status and the last 40 journal lines.

For manual installation, validate the generated JSON, choose the VPS architecture, then copy **Copy server installation script** and run it as root on the VPS, or copy **Copy host installation script** and run it on a Mac/Linux host that can reach both GitHub and the VPS. You can also export both scripts as a package. The copied host script is self-contained; it embeds the server script. Run it as `bash install-from-host.sh` if exported to a file. Optional arguments are `user@IPv4` and SSH port, with `root@<VPS IPv4>` and the wizard's SSH port as defaults. The host script downloads the matching official Linux release over IPv4, verifies its published SHA-256 digest, and transfers it with the server script. The VPS path can download and verify the archive itself if no archive was transferred. Both paths validate the config and print an `IPINFORMER_INSTALL_OK` line only when the service is active and enabled for boot. Paste the complete line into **sing-box → Client connections → Pending manual installations → Complete installation** to add the client. This matches the saved installation ID, sing-box version and exact server JSON hash, but the new client is marked **Installation not verified** because IP Informer has not independently queried the VPS. Its **Installation / Check…** view can later verify the VPS with an SSH password or key, and shows systemctl status plus recent journal output. The view also recreates and copies either installation script from the saved server JSON, so the scripts remain available after registration. Keep the exported package and copied scripts private because they contain server credentials. The VPS needs Bash, systemd, `tar` and `sha256sum`; the host path also needs `curl`, Python 3, `ssh` and `scp`.

A saved connection can become the default route or an app/group profile. **Client JSON** exports a standalone IPv4 TUN profile; **Server JSON** shows the stored VPS config. **Share QRS** transfers a standalone client profile to the official sing-box Android app. Credentials are included in the QR. The **Delete** action can remove only the local connection or also remove the VPS service after SSH authorization. For remote deletion, IP Informer verifies service ownership and deletes only its dedicated files. If the outbound was manually removed earlier, the remaining connection record and VPS service can still be removed. See [VPS_SETUP.md](VPS_SETUP.md).

## Backups and engine updates

The encrypted settings archive contains base JSON and history, groups, profiles, apps, commands, client connections and their server JSON, pending VPS installations, redirects, AI settings and readable API keys, language and launch-at-login preference. It uses AES-256-GCM with a password-derived PBKDF2-HMAC-SHA256 key. Version 3 omits retired public-IP sources, check intervals and widget settings. Versions 1 and 2 remain readable, but those retired settings are ignored on restore. Version 2 and later reject missing saved-server JSON instead of silently exporting a partial backup. Restoration applies Keychain and pending-installation changes with rollback on failure and reports rollback errors. App bundles and system binaries are not included. Missing app and command paths are disabled after restore until reselected. A service installation is needed on the destination Mac.

The **sing-box → Version** section can install an official macOS release, optionally including prereleases. Before switching, it verifies the downloaded archive, checks the binary version and validates the current JSON. Automatic stable-version installation is opt-in and does not run while a patched engine is active. The version history records dates, checksums, release notes, validation results and changed JSON paths without secret values.

For manual installation:

```sh
brew install sing-box
sing-box check -c "$HOME/Library/Application Support/IPInformer/sing-box.json"
```

## System service and PF

The installer configures a LaunchDaemon and PF kill switch after validating the configuration:

The **sing-box** tab shows whether the managed network service, updater service and any external sing-box processes are present. It can install, restart or remove the two IP Informer services with administrator authorization. Removing them keeps saved server connections and binaries.

```sh
cd /path/to/ipinformer
sudo scripts/install-network-service.sh
```

PF passes `lo0` traffic, including localhost Docker Desktop ports. It redirects user traffic for private IPv4 destinations into `utun100`, even when macOS has a preferred local route. sing-box then applies app and group policy and uses an allowed direct path when appropriate. If TUN disappears, user traffic remains blocked. IP Informer should be the only owner of its TUN; stop another sing-box service before installation. After changing the bundled PF rule, rerun the installer. To apply only the PF anchor without restarting sing-box:

```sh
sudo install -o root -g wheel -m 644 scripts/service/com.ipinformer.pf /etc/pf.anchors/com.ipinformer
sudo pfctl -a com.ipinformer -f /etc/pf.anchors/com.ipinformer
```

The managed service status checks its process and TUN interface locally. The **Check with sing-box** action validates the generated configuration.
