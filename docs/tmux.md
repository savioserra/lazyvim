# tmux config

Target: `~/.tmux.conf` (from `dot_tmux.conf`) and `~/.config/tmux/themes/tmux2k.conf`. Unix only — excluded on Windows via `.chezmoiignore`.

## `dot_tmux.conf`

| Setting | Value | Effect |
| --- | --- | --- |
| `escape-time` | 10 | Responsive input in Neovim |
| `focus-events` | on | Focus events forwarded to apps |
| `mouse` | on | |
| `default-terminal` | `tmux-256color` | |
| `terminal-features[100]` | `xterm-256color:RGB` | True color |
| `@tmux_navigator_disable_when_zoomed` | 1 | Keeps Ctrl-hjkl working in a zoomed Neovim pane |

Sources `~/.config/tmux/themes/tmux2k.conf` for status-bar presentation; runs `~/.tmux/plugins/tpm/tpm` last to initialize TPM.

## Plugins and pinned commits

TPM's `'user/repo#<ref>'` syntax only accepts branches/tags, not raw SHAs (`git clone -b <ref> --single-branch`). Pinning is done directly in `home/.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl` instead; `dot_tmux.conf`'s `@plugin` lines stay bare `user/repo`.

| Plugin | Commit |
| --- | --- |
| tmux-plugins/tpm | `e261deb1b47614eed3400089ce7197dc68acc4eb` |
| 2KAbhishek/tmux2k | `07b3228b56c1a7b6109f00009df80b53f7eae892` |
| tmux-plugins/tmux-yank | `acfd36e4fcba99f8310a7dfb432111c242fe7392` |
| christoomey/vim-tmux-navigator | `e41c431a0c7b7388ae7ba341f01a0d217eb3a432` |
| tmux-plugins/tmux-resurrect | `cff343cf9e81983d3da0c8562b01616f12e8d548` |

Fixing drift on an already-cloned plugin at the wrong commit: re-run the script (`chezmoi apply` re-runs it on content change) or delete `~/.tmux/plugins/<name>` and re-apply.

`tmux-fingers` is intentionally not managed: its bootstrap downloads the latest executable without a checksum, and upstream does not publish an Intel macOS executable. That conflicts with this repository's pinned, cross-platform dependency model.

## `tmux2k.conf` (theme)

Palette: tender.vim (`jacoborus/tender.vim`), matching Neovim's colorscheme (see [nvim.md](nvim.md)).

| Setting | Value |
| --- | --- |
| `@tmux2k-theme` | `catppuccin` (layout preset only — every color variable is overridden below it) |
| `@tmux2k-show-powerline` | true, round separators (Nerd Font PUA `U+E0B4`/`U+E0B6`) |
| `@tmux2k-left-plugins` | `session cwd` (no `git` segment — Neovim's lualine already shows branch/diff) |
| `@tmux2k-right-plugins` | `time` |
| Colors | `black`/`text` `#282828`, `white` `#eeeeee`, `gray`/`pane-border` `#666666`, `blue` `#73cef4`, `green` `#c9d05c`, `yellow` `#ffc24b` — all from tender.vim's palette |
| Window list | Centered, compact, format `#I:#W`, activity flags on |
