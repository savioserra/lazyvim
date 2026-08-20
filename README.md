# LazyVim

A chezmoi-managed Neovim and tmux environment for Linux, macOS, and Windows. Configuration deployment, host-tool provisioning, and lock restoration are owned entirely by chezmoi and by each tool's own native mechanism (lazy.nvim, mason.nvim, nvim-treesitter, TPM) — no custom CLI or build step required.

## Reproducibility boundary

| Layer | Source of truth |
| --- | --- |
| Neovim, ripgrep, fd, fzf, lazygit, tree-sitter CLI, font | `home/.chezmoiexternal.toml.tmpl` (chezmoi's native `archive`/`archive-file` externals, checksum-verified) |
| chezmoi itself | Installed independently (see Install below) — chezmoi can't provision itself |
| LazyVim and Neovim plugins | `home/dot_config/nvim/lazy-lock.json`, restored by lazy.nvim itself (`:Lazy restore`) |
| LSP servers, formatters, linters, and debuggers | `home/dot_config/nvim/mason-lock.json`, restored by [mason-lock.nvim](https://github.com/zapling/mason-lock.nvim) (`:MasonLockRestore`) |
| Tree-sitter parsers | nvim-treesitter's own `ensure_installed`/auto-install, following the locked plugin commit |
| Neovim configuration | `home/dot_config/nvim/` |
| tmux extensions | Pinned to exact commits and installed by `home/.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl` (TPM loads them; TPM's own `#<ref>` pinning only accepts branches/tags, not raw commit SHAs, so this script owns pinning directly via git) |
| tmux configuration and tmux2k theme | `home/dot_tmux.conf` and `home/dot_config/tmux/themes/tmux2k.conf` |

Chezmoi applies Neovim to `~/.config/nvim` and tmux to `~/.tmux.conf`. Native Windows ignores tmux (see `home/.chezmoiignore`). Generated plugins, tools, logs, caches, sessions, and editor history remain outside Git.

## Supported hosts

| Platform | Architectures |
| --- | --- |
| Linux | x86_64 |
| macOS | Apple Silicon and Intel |
| Windows 10/11 | ARM64 and x64 |

WSL is treated as Linux.

### Prerequisites

Linux and macOS need tmux 3.2+ and Bash 5.2+ for the managed tmux2k status bar, plus `git` (used directly by the tmux-plugin-pinning script).

Ubuntu/Zorin:

```bash
sudo apt install tmux git
```

macOS:

```bash
xcode-select --install
brew install tmux git
```

## Install

Install [chezmoi](https://www.chezmoi.io) itself first — it can't provision itself, so this is the one manual step:

```bash
# Linux/macOS
sh -c "$(curl -fsLS get.chezmoi.io)"
```

```powershell
# Windows
winget install twpayne.chezmoi
```

Then initialize and apply this repository. `.chezmoiroot` in the repo points chezmoi at the `home/` subdirectory as the actual source state:

```bash
chezmoi init --apply savioserra/lazyvim
```

This single command deploys Neovim/tmux configuration, downloads and checksum-verifies Neovim/ripgrep/fd/fzf/lazygit/tree-sitter/the Nerd Font into `~/.local/bin` and `~/.local/opt/nvim`, installs the pinned tmux plugins, and (on Windows) adds those directories to your user `PATH`. On Linux/macOS, `~/.local/bin` is expected to already be on `PATH` (add it to your shell rc if it isn't).

Once applied, open Neovim once to let lazy.nvim and Mason install everything locked in `lazy-lock.json`/`mason-lock.json`:

```bash
nvim
:Lazy restore
:MasonLockRestore
```

## Workflow

There is no wrapper CLI — use chezmoi directly:

```bash
chezmoi diff              # preview what would change
chezmoi apply              # apply repository configuration + host tools
chezmoi re-add              # capture live edits back into the repository
chezmoi update              # git pull + apply
```

Edit-and-capture loop:

```bash
nvim ~/.config/nvim/lua/config/options.lua
chezmoi diff
chezmoi re-add
git -C ~/.local/share/chezmoi diff
git -C ~/.local/share/chezmoi commit -m "feat: update development configuration"
```

Restoring locked state (rarely needed — lazy.nvim/mason.nvim/tree-sitter auto-install on a fresh machine; these fix drift on an existing one):

```text
:Lazy restore          " Neovim plugins back to lazy-lock.json
:MasonLockRestore       " Mason tools back to mason-lock.json
:TSUpdateSync            " Tree-sitter parsers
```

Updating a pinned host tool: change its version, URL, and checksum together in `home/.chezmoiexternal.toml.tmpl`, then `chezmoi apply`.

Updating a pinned tmux plugin: change its commit in `home/.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl`, then `chezmoi apply`.

## Repository layout

```text
.
├── home/                              # chezmoi source state (.chezmoiroot)
│   ├── .chezmoiexternal.toml.tmpl        # pinned host-tool downloads (nvim, rg, fd, fzf, lazygit, tree-sitter, font)
│   ├── .chezmoiscripts/                  # run_onchange_ scripts: tmux plugin pinning, Windows PATH/fonts, Linux fontcache
│   ├── .chezmoiignore                    # platform-conditional exclusions
│   ├── dot_config/nvim/                  # Neovim configuration
│   ├── dot_config/tmux/themes/           # tmux2k theme
│   ├── dot_local/bin/symlink_nvim.tmpl   # ~/.local/bin/nvim -> ~/.local/opt/nvim/bin/nvim (Unix)
│   └── dot_tmux.conf                     # tmux configuration
└── .github/workflows/ci.yml           # applies into a scratch HOME on every supported platform
```

Reference documentation (structure, pinned tools, per-area config maps): [docs/index.md](docs/index.md).

## Design notes

- TPM's `'user/repo#<ref>'` pinning syntax only accepts branches and tags — it clones via `git clone -b <ref> --single-branch`, which rejects a raw commit SHA. Exact-commit pinning for tmux plugins is therefore done directly with `git clone`/`git checkout` in `run_onchange_after_30-tmux-plugins.sh.tmpl` rather than through TPM's own install path.
- Host tool updates remain intentional: change version, URL, and checksum together in `.chezmoiexternal.toml.tmpl`.
