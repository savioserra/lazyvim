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

## Bootstrap

One command installs chezmoi (it can't provision itself, so this is the exception) and immediately applies this repository — chezmoi's official installer forwards everything after `--` to the freshly installed binary. This repo is **private**, so `--ssh` is required (a working SSH key for GitHub must already be set up) — the bare `user/repo` shorthand defaults to anonymous HTTPS and fails to clone:

```bash
# Linux/macOS
sh -c "$(curl -fsLS https://get.chezmoi.io)" -- \
  -b "$HOME/.local/bin" -t v2.72.0 -- \
  init --apply savioserra/lazyvim --ssh
```

```powershell
# Windows
winget install --id twpayne.chezmoi --version 2.72.0 --exact
chezmoi init --apply savioserra/lazyvim --ssh
```

`.chezmoiroot` in the repo points chezmoi at the `home/` subdirectory as the actual source state. This deploys Neovim/tmux configuration, downloads and checksum-verifies Neovim/ripgrep/fd/fzf/lazygit/tree-sitter/the Nerd Font into `~/.local/bin` and `~/.local/opt/nvim`, installs the pinned tmux plugins, and (on Windows) adds those directories to your user `PATH`. On Linux/macOS, `~/.local/bin` is expected to already be on `PATH` (add it to your shell rc if it isn't).

Once applied, open Neovim once to let lazy.nvim and Mason install everything locked in `lazy-lock.json`/`mason-lock.json`:

```bash
nvim
:Lazy restore
:MasonLockRestore
```

## Sync

From the repository root, pull the latest state, re-apply it, and restore every editor lock with:

```bash
./sync
```

```powershell
# Windows
.\sync.ps1
```

Both scripts supply their own repository path to chezmoi, so they work from chezmoi's normal source directory or a regular Git clone. They use blocking Lazy and Tree-sitter operations and separate Neovim processes rather than fixed sleeps, which can quit Neovim during an install. The PowerShell script also finds chezmoi's managed `nvim.exe` directly when the current terminal has not picked up the newly changed user `PATH` yet.

## Workflow

Use chezmoi directly for individual source-state operations; `./sync` on Unix or `.\sync.ps1` on Windows is the convenience wrapper for the complete update and restore sequence:

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

Restoring locked state individually (rarely needed — lazy.nvim/mason.nvim/tree-sitter auto-install on a fresh machine; these fix drift on an existing one; see Sync above for the combined script):

```text
:Lazy restore          " Neovim plugins back to lazy-lock.json
:MasonLockRestore       " Mason tools back to mason-lock.json
:TSUpdate                " Tree-sitter parsers
```

Updating a pinned host tool: change its version, URL, and checksum together in `home/.chezmoiexternal.toml.tmpl`, then `chezmoi apply`.

Updating a pinned tmux plugin: change its commit in `home/.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl`, then `chezmoi apply`.

## Repository layout

```text
.
├── sync                               # complete Bash update/restore workflow
├── home/                              # chezmoi source state (.chezmoiroot)
│   ├── .chezmoiexternal.toml.tmpl        # pinned host-tool downloads (see docs/tools.md)
│   ├── .chezmoiscripts/                  # run_onchange_ scripts: tmux plugin pinning, Windows PATH/fonts, Linux fontcache
│   ├── .chezmoiignore                    # platform-conditional exclusions
│   ├── dot_config/nvim/                  # Neovim configuration
│   ├── dot_config/tmux/themes/           # tmux2k theme
│   ├── dot_local/bin/symlink_nvim.tmpl   # ~/.local/bin/nvim -> ~/.local/opt/nvim/bin/nvim (Unix)
│   └── dot_tmux.conf                     # tmux configuration
└── .github/workflows/
    ├── ci.yml                         # validates and applies on every push/PR
    └── release.yml                    # publishes checksummed archives for v* tags
```

## CI/CD

GitHub Actions runs Linux, Apple Silicon macOS, Intel macOS, and Windows scratch-home applies on every push and pull request. The lint job validates both sync scripts and the JSON lockfiles.

Pushing a semantic `vMAJOR.MINOR.PATCH` tag runs the complete CI matrix first, then publishes `.tar.gz` and `.zip` source archives plus `SHA256SUMS` to a generated GitHub release.

Reference documentation (structure, pinned tools, per-area config maps): [docs/index.md](docs/index.md).

## Design notes

- TPM's `'user/repo#<ref>'` pinning syntax only accepts branches and tags — it clones via `git clone -b <ref> --single-branch`, which rejects a raw commit SHA. Exact-commit pinning for tmux plugins is therefore done directly with `git clone`/`git checkout` in `run_onchange_after_30-tmux-plugins.sh.tmpl` rather than through TPM's own install path.
- Host tool updates remain intentional: change version, URL, and checksum together in `.chezmoiexternal.toml.tmpl`.
