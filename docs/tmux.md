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
- Store exact commits in this table; the engine records the contract only —
  the retired Lua `setup`/`verify` handlers owned the actual checkouts, and
  the engine has no download recipe yet (see the prepared section below),
  so a checkout is (re)created by TPM's `prefix + I` and repairable via
  `workstation apply`'s recorded pins.
- Keep the `TMUX_PLUGIN_MANAGER_PATH` pin ahead of the TPM `run-shell`; TPM's
  default path logic alone would select the unmanaged XDG plugin root.
- Update this table with implementation pins.

TPM `user/repo#ref` supports branches/tags, not exact raw commits.

## Prepared plugin (pending provisioning)

| Plugin | Commit | Release pins |
| --- | --- | --- |
| `datamadsen/nunchux` | `1546eaa980d834c331496ea9d51942be07ea9fdd` (Release 3.1.3) | `versions.json` `nunchux_*`: release-asset SHA-256 per platform (`nunchux-linux-amd64` `d66afe3d…`, `nunchux-darwin-arm64` `c8444fd8…`) |

Nunchux (fzf popup launcher for apps, files and task runners) is prepared
but NOT active: the `@plugin` line in `.tmux.conf` stays commented out until
the engine grows download provisioning (`Source.Download` — the residual
tool/plugin provisioning gap left by the Lua setup handlers; see
[elixir](elixir.md)). Everything short of activation is in place: the root
`C-Space` chord (`@nunchux-key`, declared ahead of TPM init) and the
slot-templated `~/.config/nunchux/config` target (byte-equal to upstream's
default config, consuming theme slots — [theme](theme.md)).

Activation is deliberately gated on that machinery because upstream's
`nunchux.tmux` fetches `releases/latest` at plugin load with no checksum
and no version pin — the same exclusion-class defect as `tmux-fingers` —
and the spec-correct fix is a checksummed, pinned pre-seed of
`~/.tmux/plugins/nunchux/bin/nunchux` + `bin/.platform`, which needs the
missing recipe kind. Pre-seeding the directory before TPM's clone would
instead make TPM skip the plugin entirely (non-empty checkout).

The launch chord is **C-Space, root** (no prefix): `@nunchux-key` is set to
`C-Space` — upstream's own default — and the activation block carries the
matching commented `bind -n C-Space display-popup …` line (exact
nunchux.tmux popup command) so the chord goes live together with the
plugin. Tradeoff: root `C-Space` shadows the chord for applications inside
tmux (e.g. insert-mode completion). Revert is one line: comment the bind
line in `.tmux.conf` and re-apply.

Compliance flag: upstream ships NO LICENSE file, so the code is
all-rights-reserved by default — running it is a user-owned choice, and
the deferral keeps it out of managed hosts until provisioning can pin
exactly what ships.

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
plain terminals follow their own palette. The slot values render from the
shared theme capability envelope at apply time
([theme](theme.md)); this file is a `template = true` recipe and the tmux
package requires `theme`.

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
file, restore with `workstation apply` and remove any `tmux.conf.bak.*` it left in
`~/.config/tmux/`.

## Verification

- assert each checkout commit;
- assert the XDG symlink target;
- start an isolated tmux socket and server;
- assert session name;
- assert `@tmux2k-theme=catppuccin`;
- assert the pinned `TMUX_PLUGIN_MANAGER_PATH`;
- kill the isolated server on success or failure.
