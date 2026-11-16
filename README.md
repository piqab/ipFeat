# IP Informer

IP Informer is a macOS menu bar app and transparent desktop widget that displays your public IPv4 address. A synchronized widget appears on each display. When the address changes, the widgets blink and the app plays a sound.

## Build and run

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open "dist/IP Informer.app"
```

The menu bar icon opens Settings and a compact application panel. Each nonempty group has a colored row of app icons; ungrouped apps have a separate row. Hover to see an app name, click to launch or focus it, or right-click to move or remove it from IP Informer. The `+` icon adds one or more apps to that row. Extra icons scroll with a mouse wheel or trackpad. Removing an app from IP Informer does not delete its `.app` bundle.

In Settings, choose an IPv4 check interval from 5 seconds to 10 minutes, configure sources, and optionally launch at login. The app rotates through enabled sources and falls back to another source if one fails. A custom source may return plain IPv4 text or JSON with an `ip` field. Widget positions and visibility are saved for each display.

## Routing

The **sing-box** tab holds the base JSON configuration, DNS, servers, outbounds and client connections. Saving JSON shows a line-by-line diff; the last 30 versions are available in history. The **Profiles** tab holds route profiles. The **Applications** tab groups apps by color and route. Groups can be renamed, collapsed and reordered; a new group appears first. An app in a group follows the group route. Its personal route is shown and used when the app is moved to the ungrouped row. IP Informer adds itself with the `proxy` outbound when available.

The **Default route** controls all other apps. Choose an outbound, **This Mac only**, or **No network**. Localhost remains available in the last two modes. Each app can separately allow direct access to local IPv4 networks while its public traffic follows its assigned route. The WebKit option routes embedded web apps, including Telegram Web Apps, through `proxy`. Generated routing and DNS use IPv4; IPv6 connections are rejected.

A route's public IPv4 is checked when you assign or change a personal or group profile and shown beside the app. You can repeat that check manually. The desktop widget continues to show the system's public IPv4.

The **Terminal commands** section assigns exact executable paths such as `/usr/bin/ssh` to a route and can allow direct local IPv4 access. With the IP Informer sing-box patch, new apps ask for a route for unknown child commands by default. The choice is saved for that app and executable path. A separate, optional **Ask for a route for unlisted processes** switch covers apps, commands and background processes that are not in IP Informer. It asks on the first public IPv4 connection of each process launch. The choice lasts for that launch; private and localhost traffic is not delayed. The prompt stays open until you choose. If the first connection waits 20 seconds without an answer, it is blocked; a later choice applies to subsequent connections. Both prompt features require the patched local engine. See [NETWORK_ROUTING_SETUP.md](NETWORK_ROUTING_SETUP.md) and [SING_BOX_PATCH.md](SING_BOX_PATCH.md).

The local sing-box patch is pinned to `1.14.4-4`. It reloads app and command policy without restarting the TUN, attributes child traffic through verified parent processes, and provides the route prompts. Installing the patch needs macOS administrator authorization. While it is active, automatic engine updates are disabled; the app can restore the saved official engine. The VPS always uses official sing-box.

The **AI** tab stores multiple model profiles: OpenAI-compatible endpoints, local Ollama, Anthropic and Gemini. DeepSeek presets fill the matching endpoint and current model name. Each profile chooses the request and answer language: macOS language, Russian, English or a custom answer language. **Test model** uses the fields currently shown; **Save model** makes them available to the `?` button in a route prompt. The button sends only the shown executable and immediate parent paths and registered app name, and asks for an explanation; AI never chooses a route. API keys are stored in Keychain and included only in the password-encrypted configuration export. The route window remains open while a model works. Remote endpoints require HTTPS; local loopback endpoints may use HTTP.

## Client and server configurations

The **New server** wizard generates matching client and server JSON for a new Linux VPS, validates both with sing-box, and can install the server over SSH. Automatic pairs are available for VLESS + Reality, Shadowsocks 2022, VMess, Trojan, Hysteria2 and AnyTLS. TLS technologies can use ACME or embedded PEM certificate and key. Several client connections can be stored and selected as profiles. Each connection has **Client JSON**, **Server JSON**, and **Share QRS** actions. The QRS display transfers a standalone IPv4 client profile to the official sing-box Android app (version 1.13 or newer); it contains client credentials. Server secrets are stored in Keychain. See [VPS_SETUP.md](VPS_SETUP.md).

Settings can be exported to a password-encrypted archive and restored on another Mac. The archive contains JSON and its history, profiles, groups, app and command rules, client connections, redirects, IP sources, widget settings and launch-at-login preference. It does not contain installed `.app` bundles or the system service. Missing apps and commands are disabled during restore until their paths are selected again.
