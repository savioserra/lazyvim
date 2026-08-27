# tmux reference

| Property | Value |
| --- | --- |
| Hosts | Linux, macOS |
| Main target | `~/.tmux.conf` |
| Theme target | `~/.config/tmux/themes/tmux2k.conf` |
| Package implementation | `packages/tmux/init.lua` |
| Plugin root | `~/.tmux/plugins/` |

## Core settings

| Setting | Value |
| --- | --- |
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
| Layout | `catppuccin` preset |
| Palette | tender.vim overrides |
| Powerline | Round Nerd Font separators |
| Left | `session cwd` |
| Right | `time` |
| Window list | Centered, `#I:#W`, activity flags |

| Color role | Value |
| --- | --- |
| Black/text | `#282828` |
| White | `#eeeeee` |
| Gray/pane border | `#666666` |
| Blue | `#73cef4` |
| Green | `#c9d05c` |
| Yellow | `#ffc24b` |

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
| Data | Sanitized 32 KiB projections and 64 KiB sequenced IPC frames; no arbitrary transcript paths |

Commands are `/tmux-subagents doctor`, `prepare`, `open`, `focus`, `close`, `refresh`, `reload`, and `smoke`. The checked-in extension remains disabled until an explicit reviewed apply/reload boundary. Production reads only the canonical managed config and requires its apply-produced SHA-256 activation attestation; no config-path environment override is accepted. XState 5.32.6 and Terminal Kit 3.1.4 are installed from the exact local lock with lifecycle scripts disabled.

`index.ts` is only Pi registration and composition. `actors/system.ts` is the documented host-lifecycle seam because Pi supplies session callbacks and its event bus outside XState; it constructs the root actor and injects RPC, tmux, store, and IPC adapters. Domain and protocol modules never import that seam, and actor machines never import Pi's extension API.

### Safe deployment and rollback

Before enabling:

```bash
npm ci --omit=dev --ignore-scripts --prefix home/dot_pi/agent/extensions/tmux-subagents
find tests/tmux-subagents -name '*.test.ts' -print0 | xargs -0 node --test
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

After independent review, deploy only with `chezmoi apply`, run `/tmux-subagents reload`, start one trivial current-session async run, then run `/tmux-subagents smoke`. Smoke uses the production supervisor to verify isolated authenticated steer acknowledgement, Terminal Kit rendering, an actual renderer kill and restart, stale-generation rejection, absence of the detached created pane, the exact unchanged foreign seed-pane tuple, and unchanged real authority outside its isolated fake control. `prepare` remains cooperative; `open` starts and focuses its renderer automatically.

To disable, set `enabled=false`, apply, and reload. `PI_TMUX_SUBAGENTS_DISABLE=1` is an emergency startup/reload override, not a live-process kill switch. Rollback closes only exact extension-owned views and never stops managed runs.

## Verification

- assert each checkout commit;
- start an isolated tmux socket and server;
- assert session name;
- assert `@tmux2k-theme=catppuccin`;
- test observer argv construction, tickets, claims, tuple checks, created/adopted cleanup, and pane disappearance;
- run real observer controller tests against an isolated tmux socket;
- kill the isolated server on success or failure.
