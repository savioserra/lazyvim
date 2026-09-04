# tmux reference

| Property | Value |
| --- | --- |
| Hosts | Linux, macOS |
| Main target | `~/.tmux.conf` and `~/.config/tmux/tmux.conf` symlink |
| Theme target | `~/.config/tmux/themes/tmux2k.conf` |
| Package implementation | `packages/tmux/init.lua` |
| Plugin root | `~/.tmux/plugins/` |

## Core settings

| Setting | Value |
| --- | --- |
| `status-position` | `bottom` |
| `escape-time` | `10` |
| `focus-events` | `on` |
| `mouse` | `on` |
| `default-terminal` | `tmux-256color` |
| `terminal-features[100]` | `xterm-256color:RGB` |
| `@tmux_navigator_disable_when_zoomed` | `1` |

Load order:

1. Base tmux settings and plugin declarations.
2. `~/.config/tmux/themes/tmux2k.conf`.
3. `~/.tmux/plugins/tpm/tpm`.

`~/.config/tmux/tmux.conf` is a managed symlink to `~/.tmux.conf` so tmux
versions that load XDG config after the legacy file cannot let distribution or
desktop defaults override the managed theme.

TPM redirects its plugin root to `~/.config/tmux/plugins/` whenever an XDG
`tmux.conf` exists and then silently sources nothing from the managed root, so
`~/.tmux.conf` pins `set-environment -g TMUX_PLUGIN_MANAGER_PATH
'~/.tmux/plugins/'` before starting TPM. The package verify asserts that pin
on an isolated server.

## Plugin pins

| Plugin | Commit |
| --- | --- |
| `tmux-plugins/tpm` | `e261deb1b47614eed3400089ce7197dc68acc4eb` |
| `2KAbhishek/tmux2k` | `07b3228b56c1a7b6109f00009df80b53f7eae892` |
| `tmux-plugins/tmux-yank` | `acfd36e4fcba99f8310a7dfb432111c242fe7392` |
| `christoomey/vim-tmux-navigator` | `e41c431a0c7b7388ae7ba341f01a0d217eb3a432` |
| `tmux-plugins/tmux-resurrect` | `cff343cf9e81983d3da0c8562b01616f12e8d548` |

Pinning rules:

- Keep `@plugin` values as bare `user/repo` for TPM.
- Store exact commits in `packages/tmux/init.lua`.
- Run setup on every apply; setup fetches and checks out each commit.
- Keep the `TMUX_PLUGIN_MANAGER_PATH` pin ahead of the TPM `run-shell`; TPM's
  default path logic alone would select the unmanaged XDG plugin root.
- Update this table with implementation pins.

TPM `user/repo#ref` supports branches/tags, not exact raw commits.

## Excluded plugin

| Plugin | Reason |
| --- | --- |
| `tmux-fingers` | Unchecksummed bootstrap and no Intel macOS executable |

Setup removes stale `~/.tmux/plugins/tmux-fingers` checkouts.

## Theme

| Setting | Value |
| --- | --- |
| Layout | `catppuccin` preset (unused-slot defaults only) |
| Palette | tmux named colors following the live terminal palette |
| Powerline | Vertical bar separators (`|`) |
| Left | `session cwd` |
| Right | `time` |
| Refresh | `status-interval 5` |
| Window list | Centered, `#I:#W`, activity flags |

Colors resolve through terminal palette slots instead of hardcoded hex, so
the bar follows the active terminal theme everywhere: Omarchy retints panes
via OSC 4 on theme switch and the bar restyles without a tmux reload, and
plain terminals follow their own palette.

| Color role | Value |
| --- | --- |
| Status background | `default` (terminal background) |
| Segment text | `black` |
| Inactive window text / gray | `brightblack` |
| Pane border | `brightblack`, active `blue` |
| Session accent | `green` |
| Cwd accent | `blue` |
| Time accent | `yellow` |
| Window flags | `red`, current `brightgreen` |

Window-list colors are slot names (`bg_main blue`), not literal colors: the
active window renders as a blue segment with vertical separators on the
transparent bar and inactive windows render as plain muted text.

## Omarchy interactions

Omarchy ships its own tmux configuration in `/usr/share/omarchy/config/tmux/`
and `omarchy-refresh-tmux` copies it onto `~/.config/tmux/tmux.conf` with
`cp -f`. On a managed host that copy follows the XDG symlink and would
overwrite `~/.tmux.conf`. Never run `omarchy-refresh-tmux` or
`omarchy-refresh-config tmux/tmux.conf` here; if Omarchy ever replaces the
file, restore with `chezmoi apply` and remove any `tmux.conf.bak.*` it left in
`~/.config/tmux/`.

## Managed subagent actors

The source-managed `tmux-subagents` Pi extension is an XState v5 actor system. `pi-subagents` remains the sole lifecycle authority; one supervised mirror actor observes each visible run and child. Event-bus notifications are refresh hints, while every displayed status comes from documented RPC.

| Property | Contract |
| --- | --- |
| Authority | `pi-subagents` owns runs, contexts, controls, recovery, and receipts |
| Supervision | The root owns authority refresh/control and mirrors; the production-effects supervisor owns the renderer socket, serialized tmux operations, projection publication, and one real pane/IPC lifecycle child per view with bounded restart intensity and circuit-open receipts |
| Renderer | Separate Terminal Kit process launched only by the canonical attested `process.execPath`, over authenticated generation-private versioned NDJSON IPC |
| Prepared pane | User runs a safely quoted one-use launcher command carrying the exact attested Node and renderer paths; the foreground renderer cooperatively claims the pane |
| Automatic topology | `open` creates extension-owned windows/panes, reuses and tiles only windows whose every pane has an exact generation/tuple marker, and overflows after four windows |
| Pane identity | tmux socket/server, stable `%pane_id`, pane PID/TTY, binding UUID, Pi session/generation |
| Foreign pane safety | Never sends keys, respawns, rearranges, or kills an adopted pane |
| Created pane cleanup | Kills only after `created=true` and full tuple verification |
| Controls | Selection, refresh, acknowledged steer, confirmed interrupt/stop, and confirmed exact-identity resume use RPC only |
| Data | Sanitized 32 KiB projections, 64 KiB sequenced IPC frames, and an owner-private bounded/rotated diagnostic journal; no arbitrary transcript paths, prompts, output, control text, credentials, or environment values |

Commands are `/tmux-subagents doctor`, `diagnostics [count]`, `prepare`, `open`, `focus`, `close`, `refresh`, `reload`, and `smoke`. Every command receives a request/receipt ID; failures are durably recorded before a concise receipt-bearing error is rethrown. `diagnostics` reads at most 50 sanitized events through the supervised observer actor and shows generation health, exact smoke phase, RPC results, renderer/IPC/tmux exits, topology failures, and OTP restart/circuit receipts. The reviewed gate is enabled for clienting after the explicit chezmoi apply/reload boundary writes a matching SHA-256 activation attestation for the canonical managed config; no config-path environment override is accepted. XState 5.32.6 and Terminal Kit 3.1.4 are installed from the exact local lock with lifecycle scripts disabled.

`index.ts` is only Pi registration and composition. `actors/system.ts` is the documented host-lifecycle seam because Pi supplies session callbacks and its event bus outside XState; it constructs the root actor and injects RPC, tmux, store, and IPC adapters. Domain and protocol modules never import that seam, and actor machines never import Pi's extension API.

### Hosted Pi tmux ownership

Hosted-owned GoAkt agents are a separate explicit-opt-in execution path and do not alter the observer above. Each owns a stable tmux session and full Pi TUI with captured tmux-server PID/start-token and stable session/window/pane IDs plus names, pane PID/start-token, and TTY identity. The process is inspectable with `tmux attach -t <stable-name>` (or the test-only `-L <isolated-server>` equivalent). Cleanup and startup rollback use one client connection and one server-serialized `if-shell -F` ownership predicate before targeting the stable session ID; server/session replacement inside the former validation/kill windows fails closed and is tested. Creation and cleanup use argv arrays only; no shell command string, `send-keys`, `respawn-pane`, stdin automation, or terminal scraping is permitted. Tests supply a separate server name/config and prove cleanup preserves a foreign session. Managed `[hosted_pi].enabled` is active for owner-local actor tools; tmux remains a hosted-runtime implementation detail, not a client transport.

### Safe deployment and rollback

Before enabling:

```bash
npm ci --omit=dev --ignore-scripts --prefix home/dot_pi/private_agent/extensions/tmux-subagents
find tests/tmux-subagents -name '*.test.ts' -print0 | xargs -0 node --test
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

After independent review, deploy only with `chezmoi apply`, run `/tmux-subagents reload`, start one trivial current-session async run, then run `/tmux-subagents smoke` while that run remains visible in the authoritative RPC snapshot (a terminal run is preferred when retained). `pi-subagents` builds this snapshot from current in-memory jobs and may remove a completed job before smoke observes it, so requiring a terminal job was an unstable precondition. Smoke may use any visible run identity, routes all control through an isolated fake authority, and still compares the real authoritative snapshot before and after. Smoke uses the production supervisor to verify isolated authenticated steer acknowledgement, Terminal Kit rendering, an actual renderer kill and restart, stale-generation rejection, absence of the detached created pane, the exact unchanged foreign seed-pane tuple, and unchanged real authority outside its isolated fake control. `prepare` remains cooperative; `open` starts and focuses its renderer automatically.

To disable, set `enabled=false`, apply, and reload. `PI_TMUX_SUBAGENTS_DISABLE=1` is an emergency startup/reload override, not a live-process kill switch. Rollback closes only exact extension-owned views and never stops managed runs.

## Verification

- assert each checkout commit;
- assert the XDG symlink target;
- start an isolated tmux socket and server;
- assert session name;
- assert `@tmux2k-theme=catppuccin`;
- assert the pinned `TMUX_PLUGIN_MANAGER_PATH`;
- test observer argv construction, tickets, claims, tuple checks, created/adopted cleanup, and pane disappearance;
- run real observer controller tests against an isolated tmux socket;
- kill the isolated server on success or failure.
