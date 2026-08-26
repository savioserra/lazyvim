# tmux reference

| Property | Value |
| --- | --- |
| Hosts | Linux, macOS |
| Main target | `~/.tmux.conf` |
| Theme target | `~/.config/tmux/themes/tmux2k.conf` |
| Plugin implementation | `setup/features/tmux.lua` |
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
- Store exact commits in `setup/features/tmux.lua`.
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

## Verification

- assert each checkout commit;
- start an isolated tmux socket and server;
- assert session name;
- assert `@tmux2k-theme=catppuccin`;
- kill the isolated server on success or failure.
