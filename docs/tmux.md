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

## Verification

- assert each checkout commit;
- assert the XDG symlink target;
- start an isolated tmux socket and server;
- assert session name;
- assert `@tmux2k-theme=catppuccin`;
- assert the pinned `TMUX_PLUGIN_MANAGER_PATH`;
- kill the isolated server on success or failure.
