# Application routing with sing-box

IP Informer owns one system TUN, normally `utun100`, and routes traffic according to an app, group, command or default profile. It generates the working sing-box configuration from the base JSON in the **sing-box** tab. Imported TUN inbounds are replaced with the managed TUN; other inbounds remain. A line-by-line diff and `sing-box check` run before saving. The last 30 base JSON versions can be compared and restored.

## Profiles, apps and commands

The **Profiles** tab includes one profile for each outbound tag and built-in **No network**, **This Mac only** and **Local network** profiles. The **Applications** tab assigns a route to each group or ungrouped app. A group route takes priority over an app's saved personal route; moving the app to the ungrouped row restores its personal route. A disabled app is covered by the default route. IP Informer registers itself with `proxy` if that outbound exists. Helpers inside an app bundle follow the app rule; external helpers may require their own rule.

**Default route** applies to every other app, including disabled and unregistered ones. It can use any outbound tag, allow only localhost, or block public access. Managed default rules precede imported general rules. Localhost remains accessible in restricted modes. All ordinary traffic traverses the managed TUN; IP Informer does not silently bypass it.

Each app can permit direct local IPv4 access even while its public traffic uses a proxy or is blocked. Connected private subnets use the matching physical interface. Other private IPv4 uses a direct system route. The built-in **Local network** profile allows localhost, RFC1918, link-local and mDNS/Bonjour but rejects public destinations. Local network interface changes are checked locally about every 10 seconds. IPv6 is intercepted and rejected; DNS strategy is IPv4 only.

The **Terminal commands** section assigns a route to an exact executable path such as `/usr/bin/ssh`, `/usr/bin/curl` or `/usr/bin/nc`. This applies from any terminal. Local IPv4 access can be allowed per command, while public IPv4 follows its assigned outbound. An explicit child command choice takes priority over a global command rule, which takes priority over the app or group route. For `ssh` with `ProxyCommand`, the helper that owns the socket is routed separately.

With local patch `1.14.4-3`, newly added apps enable **Ask for a route for child commands** by default. The first public IPv4 connection from an unknown child command asks for a route, which is saved for that app and executable path. A verified parent chain attributes iTerm2 shells through `/usr/bin/login`; it does not inherit through `sudo`. A popup names the socket owner and immediate parent. If `brew` invokes `git`, the socket owner may be `git`.

An optional **Ask for a route for unlisted processes** toggle under Default route also covers apps, commands and user background processes absent from the IP Informer list. It asks on the first public IPv4 connection of each process launch. The answer lasts for that process instance. Local IPv4 connections do not wait, and if the popup cannot answer, the configured route applies. An open or expired popup cannot hold newer requests in the listener queue. Details: [SING_BOX_PATCH.md](SING_BOX_PATCH.md).

The WebKit option routes `com.apple.WebKit.Networking` through `proxy` before the default route. It can help Telegram Web Apps, but the system WebKit process may serve embedded pages from other apps too.

## Live rules and connection stability

With the patch active, IP Informer keeps a stable `sing-box-base.json` and a separate `sing-box-policy.json`. Adding, removing or moving apps rewrites only policy; sing-box reloads it without restarting TUN. Established flows retain their outbound, and new flows use the new rules. Changing base DNS, TUN or outbounds still restarts the service. An unpatched engine uses compatible `sing-box.json` and restarts on rule changes. One multi-app selection generates one update.

The patch is bundled with the app, checked by SHA-256 and `sing-box check`, then installed with macOS administrator authorization. Existing revisions 1 and 2 can be upgraded to revision 3, preserving the official binary for rollback. Automatic updates to unrelated official versions are disabled while the patch is active. The local patch is never installed on a VPS.

## New server and clients

The **sing-box → Client connections → New server** wizard creates a client/server pair for a new Linux VPS with systemd and public IPv4. It supports `x86_64` and `aarch64`/`arm64`; the VPS needs `/bin/bash`, `curl`, `tar`, `sha256sum` and working `systemctl`. Debian 13 is supported when these are present. The wizard uses the Mac's selected sing-box version and pins it to the generated configs.

Automatic pairs are available for VLESS + Reality, Shadowsocks 2022, VMess, Trojan, Hysteria2 and AnyTLS. TLS protocols can use ACME or embedded PEM certificate and private key. Other compatible inbound/outbound pairs can be edited manually. Both JSON files are checked before deployment. The installation log shows commands, remote output and exit status but omits the SSH password. The official Linux sing-box archive is checked by SHA-256, installed executable, validated, and launched as `ipinformer-sing-box`. If deployment fails, new remote files are removed.

A saved connection can become the default route or an app/group profile. **Client JSON** exports a standalone IPv4 TUN profile; **Server JSON** shows the stored VPS config. **Share QRS** transfers a standalone client profile to the official sing-box Android app. Credentials are included in the QR. The **Delete** action can remove only the local connection or also remove the VPS service after SSH authorization. For remote deletion, IP Informer verifies service ownership and deletes only its dedicated files. If the outbound was manually removed earlier, the remaining connection record and VPS service can still be removed. See [VPS_SETUP.md](VPS_SETUP.md).

## Backups and engine updates

The encrypted settings archive contains base JSON and history, groups, profiles, apps, commands, client connections, redirects, IP sources, widget settings and launch-at-login preference. It uses AES-256-GCM with a password-derived PBKDF2-HMAC-SHA256 key. App bundles and system binaries are not included. Missing app and command paths are disabled after restore until reselected. A service installation is needed on the destination Mac.

The **sing-box → Version** section can install an official macOS release, optionally including prereleases. Before switching, it verifies the downloaded archive, checks the binary version and validates the current JSON. Automatic stable-version installation is opt-in and does not run while a patched engine is active. The version history records dates, checksums, release notes, validation results and changed JSON paths without secret values.

For manual installation:

```sh
brew install sing-box
sing-box check -c "$HOME/Library/Application Support/IPInformer/sing-box.json"
```

## System service and PF

The installer configures a LaunchDaemon and PF kill switch after validating the configuration:

```sh
cd /path/to/ipinformer
sudo scripts/install-network-service.sh
```

PF passes `lo0` traffic, including localhost Docker Desktop ports. It redirects user traffic for private IPv4 destinations into `utun100`, even when macOS has a preferred local route. sing-box then applies app and group policy and uses an allowed direct path when appropriate. If TUN disappears, user traffic remains blocked. IP Informer should be the only owner of its TUN; stop another sing-box service before installation. After changing the bundled PF rule, rerun the installer. To apply only the PF anchor without restarting sing-box:

```sh
sudo install -o root -g wheel -m 644 scripts/service/com.ipinformer.pf /etc/pf.anchors/com.ipinformer
sudo pfctl -a com.ipinformer -f /etc/pf.anchors/com.ipinformer
```

The configured public IPv4 probe verifies reachability to its selected IP source. It cannot guarantee reachability to every destination through a particular route.
