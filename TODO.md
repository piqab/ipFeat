# sing-box patch status and manual checks

The contract and porting requirements are in [SING_BOX_PATCH.md](SING_BOX_PATCH.md). The implementation is [patch revision 3](patches/sing-box-1.14.4-ipinformer-3.patch), pinned to sing-box `v1.14.4` at `c005f35300ce76427dc285481ec5695f5b179cd2`. Build it with [build-patched-sing-box.sh](scripts/build-patched-sing-box.sh). This patch affects only the local macOS engine; the VPS uses official sing-box.

Implemented:

- Reload application, group and command rules from a separate JSON policy without restarting TUN. Existing flows retain their route.
- Attribute a socket to a verified PID and parent chain. A verified `/usr/bin/login` bridge allows an iTerm2 shell to inherit its app; ambiguous attribution does not borrow another app's route.
- Prompt for unknown child commands of a registered app. The saved choice belongs to the app and executable path. An explicit child choice takes priority over a global command rule, then the app/group and default route.
- Optionally prompt for an unlisted app, command or background process on the first public IPv4 connection of each launch. This choice lasts only for that process instance. Private IPv4 does not wait.
- Accept incoming prompt requests independently, discard expired queued alerts, and show the socket owner plus its immediate parent to clarify helper processes.
- Bound prompts by time, concurrency and cache size. If IP Informer is unavailable, fall back to the configured route.
- Verify the bundled patch by SHA-256 and `sing-box check`, disable incompatible engine updates, and retain the official engine for rollback.

Automated checks include Go process/routing tests, Swift configuration tests and `sing-box check` against a live base/policy pair.

Manual checks after installing revision 3 on the target Mac:

- Run `curl -4 https://api.ipify.org` and `ssh` from iTerm2, a nested shell and another terminal. Confirm the popup names the actual socket owner, appears promptly and routes each connection as selected.
- Enable the unlisted-process option and launch the same unlisted executable twice. Confirm one prompt per run, including a background or helper process. Confirm local IPv4 traffic does not trigger the popup.
- Add or move an app while another app has an active connection; the existing connection must continue.
- Check direct local IPv4 and public proxy traffic, then restore the official engine and verify the network service restarts.

A new sing-box release requires a separately ported and tested patch before it can replace this binary.
