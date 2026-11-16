# IP Informer sing-box patch

This document describes the contract between IP Informer and its local macOS sing-box engine. It is the reference for porting the patch to another sing-box release. The current source is sing-box `v1.14.4` at `c005f35300ce76427dc285481ec5695f5b179cd2`, with [patch revision 3](patches/sing-box-1.14.4-ipinformer-3.patch) built by [build-patched-sing-box.sh](scripts/build-patched-sing-box.sh). The VPS uses an official sing-box binary.

## Why the local patch exists

1. Apply app, group and command rules without restarting TUN or dropping existing connections.
2. Attribute a connection to its socket owner and verified parent chain. This lets a child such as `curl`, `ssh` or `git` inherit the relevant app's route.
3. Before a new public IPv4 connection, ask IP Informer for a route when an app's child command has no saved choice.
4. Optionally ask for a route for any unlisted app, command or background process on its first public IPv4 connection **of each launch**.

IPv4 configuration generation, profiles, groups, local network access, WebKit handling, public IP probes and the user interface live in IP Informer.

## Live policy

IP Informer writes `sing-box-base.json` and `sing-box-policy.json` under `~/Library/Application Support/IPInformer/`. The base contains TUN, DNS, inbounds, outbounds and stable rules. The policy contains rules that can change while sing-box runs:

```json
{
  "rules": [
    {"process_path_regex": ["^/Applications/Example\\.app/"], "action": "route", "outbound": "proxy"}
  ],
  "prompts": [
    {
      "application_id": "UUID",
      "application_name": "Example",
      "process_path_regex": ["^/Applications/Example\\.app/"],
      "exclude_process_paths": ["/usr/bin/ssh"]
    }
  ],
  "ask_unknown_processes": true,
  "known_process_paths": ["/usr/bin/ssh"],
  "known_process_path_regex": ["^/Applications/Example\\.app/"],
  "socket_path": "/Users/USER/Library/Application Support/IPInformer/child-route.sock"
}
```

The engine starts with `run --ipinformer-policy PATH`; validation uses `check -c BASE --ipinformer-policy POLICY`. IP Informer atomically replaces the policy file. sing-box validates a changed policy before replacing its routing table. Invalid changes leave the previous table active. Existing TCP and UDP flows keep their selected outbound; changing base outbounds, TUN or DNS still requires a service restart.

`ancestor_process_path_regex` matches only verified parent executable paths. Ordinary `process_path_regex` matches the socket owner's executable. IP Informer combines these conditions to cover an app and its descendants.

## macOS process attribution

- Look up the TCP or UDP socket owner by source address and port. Ambiguous UDP ownership must never be assigned to an arbitrary PID.
- Verify PID, UID and process start time before and after reading the executable path. Do not reuse a stale owner cache while live policy is active.
- Walk the parent chain with the same identity checks and a depth limit. Stop if identity cannot be verified.
- The iTerm2 chain may cross exactly one verified system `/usr/bin/login` process. `login` itself is not treated as the app. Do not inherit through `sudo` or another root process.
- When `proc_pidinfo(PROC_PIDTBSDINFO)` is unavailable for `login`, use `kern.proc.pid` with the same identity checks.

The implementation touches `common/process/ancestor_darwin.go`, `common/process/searcher_darwin_shared.go`, `route/process_cache.go`, `route/rule/rule_item_process_path_regex.go`, `option/rule.go` and `option/rule_set.go` in sing-box.

## Route prompts

Prompts require a verified socket owner, a public IPv4 destination and a non-DNS destination port. Private, localhost and link-local IPv4 connections use ordinary rules without waiting. For a child command, a verified parent must match a configured app, and a saved child choice or explicit command rule suppresses the prompt. The child choice is keyed by app ID and executable path and persists in IP Informer settings.

When the optional unknown-process prompt is enabled, it covers processes absent from known app and command paths. A choice is keyed by UID, PID, process start time and executable path. It applies only to that process instance, so the next launch asks again. The parent path is included in the request to help identify helpers such as `git` launched by `brew`; the socket owner remains the actual process named in the prompt. Unknown choices are kept in a bounded in-memory cache. Completed unknown choices are evicted oldest-first if the cache fills.

The engine sends a JSON line over a local Unix socket with `id`, `kind` (`child` or `unknown`), `application_id`, `application_name`, `command_path` and optional `parent_path`. The reply contains the same `id` and a route tag or `reject`. The socket and peer UID are verified; unknown tags are rejected. At most 16 prompts are in flight. The UI has an 18-second deadline and the engine has a 20-second deadline. Concurrent connections sharing a key share one request. An unanswered, invalid or timed-out request follows the app/group or default route. Expired queued prompts are discarded so they do not appear late. The UI handles incoming sockets independently so one open alert does not block receipt of another request.

IP Informer generates rules in this order: saved child command choice, global command choice, permitted direct local IPv4, app/group route, then default route. The prompt is evaluated before the ordinary rule selection. The relevant patch files are `route/ipinformer_prompt.go`, `route/ipinformer_live.go` and `route/route.go`.

## Porting and verification

1. Pin the exact upstream commit, port the source changes and update the `IPInformer patch` revision reported by `sing-box version`. Matching version numbers alone do not imply compatibility.
2. Run Go tests for process attribution, ambiguous UDP sockets, parent matching, live policy and public IPv4 prompts. Verify iTerm2 through `/usr/bin/login` and the boundary at `sudo`.
3. Run Swift generator tests and `sing-box check` for the base/policy pair. On a live TUN, check rule changes without dropping other connections, `curl -4 https://api.ipify.org` from iTerm2, public and local SSH destinations, unlisted processes across two launches, prompt timeout and official-binary rollback.
4. Update the build and installer scripts, bundled SHA-256, and the guard against incompatible automatic official updates. Keep the official binary for rollback.

Prompt interception requires the patched local engine and a running IP Informer. The per-app child prompt is enabled by default for newly added apps; saved settings for existing apps are unchanged. The global unknown-process prompt is off by default.
