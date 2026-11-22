# ipFeat sing-box patch

This document is the complete source and behavior checklist for porting the local macOS sing-box patch. The base is sing-box `v1.14.4` at commit `c005f35300ce76427dc285481ec5695f5b179cd2`. [Patch revision 6](patches/sing-box-1.14.4-ipfeat-6.patch) is applied by [build-patched-sing-box.sh](scripts/build-patched-sing-box.sh). VPS installations use an official sing-box binary.

## Why the local patch exists

1. Apply app, group and command rules without restarting TUN or dropping existing connections.
2. Attribute a connection to its socket owner and verified parent chain. This lets a child such as `curl`, `ssh` or `git` inherit the relevant app's route.
3. Before a new public IPv4 connection, ask ipFeat for a route when an app's child command has no saved choice.
4. Optionally ask for a route for any unlisted app, command or background process on its first public IPv4 connection. A saved route applies to later launches; a one-time choice applies only to the current launch.
5. Apply global domain routes without a child or unknown process prompt when DNS mapping or protocol sniffing identifies a matching hostname.

IPv4 configuration generation, profiles, groups, local network access, WebKit handling and the user interface live in ipFeat.

## Complete source inventory

The patch changes these 23 sing-box source files. When porting, review each change against the target release; a successful textual apply is insufficient.

| File | Required change |
| --- | --- |
| `adapter/platform.go` | Add process start time and verified ancestor executable paths to `ConnectionOwner`. |
| `cmd/sing-box/cmd.go` | Register the `--ipfeat-policy` CLI flag. |
| `cmd/sing-box/cmd_check.go` | Validate the policy alongside the base config in `sing-box check`. |
| `cmd/sing-box/cmd_run.go` | Load policy before starting, then watch its SHA-256 for live updates. |
| `cmd/sing-box/cmd_version.go` | Print the exact `ipFeat patch: 1.14.4-6` marker. |
| `common/process/ancestor_darwin.go` | Read verified process identity and walk the Darwin parent chain. |
| `common/process/ancestor_darwin_test.go` | Test identity, UID, login bridge and ancestry. |
| `common/process/searcher_darwin_shared.go` | Verify socket owner identity before attributing the path; reject ambiguous UDP owners. |
| `option/rule.go` | Accept `ancestor_process_path_regex` in route rules. |
| `option/rule_set.go` | Accept the same condition in headless rule sets. |
| `route/ipfeat_live.go` | Validate and atomically replace live rules, prompt metadata, known paths and domain prompt exclusions; invalidate removed saved decisions. |
| `route/ipfeat_prompt.go` | Identify eligible public IPv4 flows, skip prompts for matching exact or suffix domains, request other routes through the local socket and cache process decisions. |
| `route/ipfeat_prompt_test.go` | Test child and unknown prompts, domain exclusions, delayed replies and cache invalidation. |
| `route/process_cache.go` | Bypass stale Darwin process-owner cache while live policy is enabled. |
| `route/route.go` | Run non-final sniff actions before deciding whether to prompt; use the live rules for matching. |
| `route/router.go` | Hold atomic policy and synchronized prompt state; expose current rules. |
| `route/rule/rule_default.go` | Compile ancestor conditions in ordinary rules. |
| `route/rule/rule_headless.go` | Compile ancestor conditions in headless rules. |
| `route/rule/rule_item_process_path_regex.go` | Match regexes against the owner path or verified ancestor paths. |
| `route/rule/rule_item_process_path_regex_test.go` | Test owner and ancestor matching boundaries. |
| `route/rule/rule_set.go` | Classify ancestor conditions as process rules. |
| `route/rule/rule_set_local.go` | Synchronize reads and cleanup of local rule sets. |
| `route/rule_conds.go` | Classify ancestor conditions as process conditions. |

## Live policy

ipFeat writes `sing-box-base.json` and `sing-box-policy.json` under `~/Library/Application Support/ipFeat/`. The base contains TUN, DNS, inbounds, outbounds and stable rules. The policy contains rules that can change while sing-box runs:

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
  "prompt_bypass_domains": ["example.org"],
  "prompt_bypass_domain_suffixes": [".com", ".blabla.eu"],
  "known_process_paths": ["/usr/bin/ssh", "/opt/homebrew/bin/brew"],
  "known_process_path_regex": ["^/Applications/Example\\.app/"],
  "socket_path": "/Users/USER/Library/Application Support/ipFeat/child-route.sock"
}
```

The engine starts with `run --ipfeat-policy PATH`; validation uses `check -c BASE --ipfeat-policy POLICY`. ipFeat atomically replaces the policy file. sing-box checks its SHA-256 every 250 ms and applies changed content after validating it. Invalid content leaves the previous table active and is logged; the watcher retries when the file content changes again. An absent or invalid policy at engine startup prevents startup. Existing TCP and UDP flows keep their selected outbound. Changing base outbounds, TUN or DNS still requires a service restart.

The policy accepts at most 2 MiB, 4,096 route rules, 256 prompt definitions, 4,096 known paths and 4,096 known path regexes. Live route rules must be self-contained ordinary or logical rules; rule-set references are rejected. Every route outbound must already exist in the base configuration. The live rules precede the base rules. `known_process_paths` includes configured commands and permanent routes saved from prompts; `known_process_path_regex` includes configured apps. A child prompt's `exclude_process_paths` includes its saved child commands, configured global commands and permanent process routes.

Revision 6 also accepts at most 4,096 exact or suffix domain prompt exclusions. They mirror the global domain rules in the live rule table. A suffix starts with a dot, so `.blabla.eu` matches subdomains and excludes the bare `blabla.eu`. The engine evaluates non-final sniff actions before deciding whether to prompt; a matching global domain route then takes precedence. If the hostname remains unknown, the normal process prompt and route policy still apply. Ordinary sing-box clients use the same standard `domain` and `domain_suffix` route rules in the exported client JSON and do not need this patch.

`ancestor_process_path_regex` matches only verified parent executable paths. Ordinary `process_path_regex` matches the socket owner's executable. ipFeat combines these conditions to cover an app and its descendants.

## macOS process attribution

- Look up the TCP or UDP socket owner by source address and port. Ambiguous UDP ownership must never be assigned to an arbitrary PID.
- Verify PID, UID and process start time before and after reading the executable path. Do not reuse a stale owner cache while live policy is active.
- Walk at most 16 parent processes with the same identity checks. Stop if identity cannot be verified, a PID is reused, a parent starts after its child, or the chain crosses an unauthorized UID boundary.
- The iTerm2 chain may cross exactly one verified system `/usr/bin/login` process. `login` itself is not treated as the app. Do not inherit through `sudo` or another root process.
- When `proc_pidinfo(PROC_PIDTBSDINFO)` is unavailable for `login`, use `kern.proc.pid` with the same identity checks.

When attribution is uncertain, do not invent a parent or show a process prompt. The connection falls through to the ordinary routing policy. `ancestor_process_path_regex` is available in ordinary and headless rules, matches verified ancestor paths only, and never matches the socket owner's path. Live policy disables the long-lived process-owner cache on macOS, because source ports can be reused by another program.

## Route prompts

Prompts require a verified socket owner, a global-unicast, non-private IPv4 destination and a destination port other than 53. Private, localhost, link-local, multicast, invalid and IPv6 destinations use ordinary rules without waiting. A child command needs a verified ancestor matching an enabled app with child prompts enabled. Saved child choices, configured global commands and saved process routes suppress the corresponding child prompt. A child choice is keyed by app ID and executable path and persists in ipFeat settings. The unknown-process prompt is evaluated after child prompts and only for a user process with UID at least 500 and a verified PID and start time.

When the optional unknown-process prompt is enabled, it covers processes absent from known app and command paths. **Save route** creates a permanent executable-path rule in ipFeat; it is included in encrypted backups and later launches do not prompt. **Use once** keeps the selected route only for the current process instance. These are UI choices: the engine receives a route tag or `reject` in both cases, while ipFeat separately writes a saved choice into its configuration and live policy. A transient choice is keyed by UID, PID, process start time and executable path. The parent path is included in the request to help identify helpers such as `git` launched by `brew`; the socket owner remains the actual process named in the prompt. The cache holds at most 1,024 entries; completed unknown entries are evicted oldest-first if it fills. Revision 6 removes cached unknown choices for a path when that path is removed from `known_process_paths`, so deleting a saved route can prompt again on the next eligible connection from the same running process. Ordinary policy updates preserve unrelated unknown choices.

The engine sends one JSON line over a local Unix socket with `id`, `kind` (`child` or `unknown`), `application_id`, `application_name`, `command_path` and optional `parent_path`. The reply contains the same `id` and either an existing outbound tag, `reject`, or `use_default: true` for the ordinary policy. `reject` blocks the public connection. The engine checks that the socket is owned by a non-root user and that the peer UID matches the socket owner; unknown tags and malformed replies are rejected. At most 16 prompts are in flight. Each connection waits up to 20 seconds, then is blocked if no answer has arrived. The socket request remains open while the route panel remains open; a later answer applies to subsequent flows from that process. An absent UI, invalid answer or a full prompt queue also blocks the eligible connection. Each prompt has its own panel without an automatic close timer, so waiting for an AI response in one panel does not hide another process's prompt. Concurrent connections sharing a key share one request.

ipFeat generates rules in this order: IPv6 rejection, updater rule, domain sniffing, app redirects, local allowances and explicit app restrictions, global domain routes, saved child command choice, saved process route, global command choice, app/group route, then default route. The prompt is evaluated after non-final sniff actions and before the first ordinary final rule, unless a global domain route matches. The relevant patch files are `route/ipfeat_prompt.go`, `route/ipfeat_live.go` and `route/route.go`.

ipFeat owns the corresponding configuration and UI in `RoutingModels.swift`, `RoutingStore.swift`, `SingBoxConfiguration.swift`, `ChildRoutePromptServer.swift` and `RoutePromptPanel.swift`. The Go patch does not persist saved routes, know about group names or choose an AI model. ipFeat writes those choices into the live policy and stores them in its encrypted configuration backup. IPv6 rejection and the direct local IPv4 rules are also generated by ipFeat, not by the prompt code.

## Porting and verification

1. Pin the exact upstream commit and review all 23 files above against the new APIs, process structures and rule compiler. Recheck Darwin `proc_bsdinfo` layout and socket-owner lookup. A matching sing-box version number or a clean textual apply does not establish compatibility.
2. Port the policy CLI, startup validation, 250 ms watcher, atomic routing table swap, ancestor matcher, process attribution and prompt protocol together. Update the `ipFeat patch` marker in `cmd_version.go`; ipFeat uses this marker and the installed engine path to detect a compatible local patch.
3. Update `scripts/build-patched-sing-box.sh`, `scripts/build-app.sh`, `scripts/install-patched-engine.sh`, `EngineManager.swift` and `SingBoxSettingsView.swift` to the new revision. Rebuild the bundled binary, regenerate its SHA-256 file and sign the app. Preserve the official engine for rollback and keep automatic official updates disabled while the patched engine is active.
4. Run the Go tests for process identity, ambiguous UDP ownership, the login bridge, `sudo` boundary, ancestor rule compilation, live policy, public IPv4 prompts, delayed replies and saved route deletion. Run Swift generator and backup tests; validate both base and policy with the patched `sing-box check`.
5. On a live TUN, verify that editing and bulk moving app or group rules does not restart the engine or drop unrelated existing flows. Check `curl -4 https://api.ipify.org` from iTerm2, public and local SSH, a saved unlisted process across two launches, **Use once** across two launches, a deleted saved route in an already-running process, a prompt left open beyond 20 seconds, and rollback to the official engine.

Prompt interception requires the patched local engine and a running ipFeat. The per-app child prompt is enabled by default for newly added apps; saved settings for existing apps are unchanged. The global unknown-process prompt is off by default.
