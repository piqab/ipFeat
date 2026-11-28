# ipFeat

ipFeat is a macOS routing app for programs, terminal commands, and domains. It builds IPv4 sing-box configurations from saved server connections and applies per-program rules through a managed TUN. The app has a Dock icon and a compact menu bar panel.

## Requirements

- macOS 13 or later; administrator authorization is required to install the local network service and PF rules.
- Xcode and Go 1.25.5 or later to build the bundled sing-box patch from source. The app can also use an already built patch binary.
- A Linux VPS with systemd and public IPv4 for the optional server wizard. Supported architectures are `x86_64` and `aarch64`/`arm64`.

## Build and launch

```sh
swift scripts/generate-app-icon.swift Resources
./scripts/build-app.sh
open "dist/ipFeat.app"
```

`build-app.sh` builds both Swift executables, packages the monochrome Dock icon and menu bar template, builds the pinned local sing-box patch, and signs the app for local use. To reuse a previously built patch binary, set `IPFEAT_PATCHED_BINARY=/absolute/path/to/sing-box` for the build command. The source and patch contract are documented in [SING_BOX_PATCH.md](SING_BOX_PATCH.md).

After a pull request is merged into `main`, [the release workflow](.github/workflows/release.yml) builds the arm64 app and pinned patch on a GitHub macOS runner. It reads the app version from `Resources/Info.plist`, runs Swift tests, and creates a release named `ipfeat-VERSION` with a ZIP and SHA-256 checksum. A later push with the same version does not replace the release. Bump the app version for each new release. The app is currently signed ad hoc and is not notarized. On a Mac that blocks its first launch, use Apple's [Open Anyway](https://support.apple.com/en-us/102445) steps in System Settings → Privacy & Security after verifying the download.

On first launch, open **sing-box** to install the bundled patch and the managed network service. The service runs sing-box at login, maintains `utun100`, and applies a PF kill switch for every UID. A dedicated `_ipfeat_engine` group lets only sing-box itself open physical outbound sockets. **sing-box** also contains the interface language and launch-at-login settings. The **Programs**, **Profiles**, and **AI** tabs handle routing rules, named routes, and process explanations.

If you need to stop the managed service and clear its PF rule from Terminal, run:

```sh
sudo ipfeat-recover
```

## Routing

- **Profiles** contain saved server outbounds plus **Local network**, **This Mac only**, and **No network**. A group route applies to all its programs. An ungrouped program can use its personal profile. The default route covers everything else.
- **Programs** lists groups, ungrouped apps, terminal commands, and routes saved from prompts. Its shared search field sits directly above the program list and searches names and executable paths. Domain rules have their own search field.
- **Domain routes** apply across programs, with exact patterns such as `example.com` and suffix patterns such as `*.example.com`. More specific rules win. Matching requires a known hostname; connections made directly to an IP address cannot match a domain rule.
- Programs and commands can allow direct access to local IPv4 networks while public traffic follows a proxy or another selected route. Generated DNS and routing use IPv4; IPv6 connections are rejected.
- The shared WebKit networking process can use a selected profile. This can affect embedded pages in several programs.

The bundled sing-box patch reloads app, command, and domain policy without restarting the TUN, so existing flows keep their route during ordinary rule changes. It attributes child traffic through a verified process ancestry. Newly added apps ask for a route when an unknown child command makes its first public IPv4 connection. An optional setting also prompts for unlisted apps and background processes. **Save route** creates a lasting rule; **Use once** applies to the current process launch. An unanswered first connection is blocked after 20 seconds, while the prompt stays open for later connections. Base DNS, TUN, or outbound changes still require a service restart. See [NETWORK_ROUTING_SETUP.md](NETWORK_ROUTING_SETUP.md) for rule order and network behavior.

The **AI** tab supports OpenAI-compatible endpoints, Ollama, Anthropic, and Gemini. Its `?` button can explain a process shown in a route prompt; it never chooses a route. Remote model endpoints require HTTPS. API keys are stored in Keychain.

## Client and server connections

**sing-box → Client connections → New server** generates a matching client/server JSON pair for VLESS + Reality, Shadowsocks 2022, VMess, Trojan, Hysteria2, or AnyTLS. TLS options include ACME and embedded PEM files. The wizard validates both files before installation. Its SSH installer downloads the selected official Linux sing-box release over IPv4, verifies its SHA-256 digest, installs a systemd service, and checks the resulting config hash, version, files, and active service independently. An interrupted or unverified installation remains pending with its log.

For a VPS that cannot be reached directly from the Mac, the wizard can copy a standalone server installer or a host script that downloads the release and connects to the VPS over SSH. A successful manual run prints an `IPFEAT_INSTALL_OK` receipt; paste that receipt into the pending installation to add its client. Manual receipts are marked unverified until ipFeat checks the VPS over SSH. Installation scripts and client QR codes contain credentials; keep them private.

Each saved connection provides **Client JSON**, **Server JSON**, and **Share QRS**. The client JSON and QRS include enabled global domain rules and their required outbounds. Import QRS again on Android after changing those rules. The Android client uses its own local network for `direct`.

The **Installation / Check…** view checks a saved VPS and can migrate an earlier `ipinformer-sing-box` systemd service to `ipfeat-sing-box` after verifying its config and binary. It also supports removal of either service name. Remote service migration requires SSH authorization for that VPS. The old server files stay as a rollback copy until the migrated service is removed through ipFeat.

## Backups and upgrades

**sing-box → Transfer to another Mac** exports a password-encrypted archive containing profiles, routing rules, JSON and history, saved client and server connections, pending VPS installations, AI profiles and readable API keys, language, launch-at-login preference, and traffic history with independent reset baselines. Version 4 adds traffic statistics and still omits the retired public-IP widget settings. Versions 1–3 remain readable. App bundles, installed sing-box binaries, and the macOS service are not included; install the service on the destination Mac after restoring.

The rename from IP Informer to ipFeat changes the app bundle identifier, support directories, Keychain service names, and managed service names. On first launch, ipFeat copies existing user settings and support files without overwriting new data, and reads old Keychain records when needed. Installing the ipFeat network service replaces the old LaunchDaemon and PF anchor after validating the new configuration. The old support directory remains as a rollback copy. If an old login item is still registered, turn it off in the old app and enable **Launch at login** in ipFeat.

The local patched engine is pinned to sing-box `1.14.4-8`. Automatic installation of an unrelated official engine version is disabled while the patch is active. VPS installations use official sing-box releases. For patch behavior and future ports, see [SING_BOX_PATCH.md](SING_BOX_PATCH.md).

## Traffic statistics

The **Traffic** tab shows IPv4 upload and download by actual outbound route and registered program for today, this month, or all time. Each route and program has its own reset button. The patched service checkpoints counters every two seconds, including while the ipFeat window is closed. Verified child processes count under their nearest registered parent. Unknown owners remain in route totals. Only traffic handled by sing-box is counted; local or other traffic that bypasses its TUN is outside these figures. Statistics include byte counts and executable paths but no destination addresses, domains, or packet contents.

Each program row in **Programs** also shows total download and upload across all routes since that program's last reset, plus current download and upload rates. The row has an individual reset button. Both views use the same counters.
