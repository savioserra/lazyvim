# Cross-platform development dotfiles

A chezmoi-managed Neovim and tmux environment for Linux, macOS, and Windows. A single Go/Cobra CLI now owns installation, verified downloads, configuration deployment, lock restoration, validation, updates, and synchronization; no Bash or PowerShell implementation is required.

## Reproducibility boundary

| Layer | Source of truth |
| --- | --- |
| Neovim, chezmoi, ripgrep, fd, fzf, lazygit, tree-sitter CLI, font | `manifests/tools.env` |
| LazyVim and Neovim plugins | `home/dot_config/nvim/lazy-lock.json` |
| LSP servers, formatters, linters, and debuggers | `home/dot_config/nvim/mason-lock.json` |
| Tree-sitter parsers | Revisions supplied by the locked `nvim-treesitter` plugin |
| Neovim configuration | `home/dot_config/nvim/` |
| tmux extensions | `manifests/tmux-plugins.lock` |
| tmux configuration and tmux2k theme | `home/dot_tmux.conf` and `home/dot_config/tmux/themes/tmux2k.conf` |

Chezmoi applies Neovim to `~/.config/nvim` and tmux to `~/.tmux.conf`. Native Windows ignores tmux and junctions `%LOCALAPPDATA%\nvim` to the managed configuration. Generated plugins, tools, logs, caches, sessions, and editor history remain outside Git.

## Supported hosts

| Platform | Architectures |
| --- | --- |
| Linux | x86_64 |
| macOS | Apple Silicon and Intel |
| Windows 10/11 | ARM64 and x64 |

WSL is treated as Linux. Intel macOS uses fd 10.3.0 because newer releases no longer publish Intel binaries.

### Prerequisites

A published release binary needs no Go toolchain. Configured Mason packages still need a C compiler and Node.js/npm. Linux and macOS need tmux 3.2+ and Bash 5.2+ for the managed tmux2k status bar. Building the CLI from source additionally requires Go.

Ubuntu/Zorin:

```bash
sudo apt install build-essential git tmux nodejs npm golang-go
```

macOS using the published binary:

```bash
xcode-select --install
brew install bash git node tmux
```

Add `go` to the Homebrew command only when building from source.

Windows:

```powershell
winget install --id Git.Git
winget install --id OpenJS.NodeJS.LTS
winget install --id GoLang.Go
winget install --id LLVM.LLVM
```

A published prebuilt `dotfiles` binary does not require Go for installation. It embeds the manifests and chezmoi source state, and can optionally embed all pinned release archives.

## Install

### Published binary on macOS—no Go required

Every version tag publishes GitHub release assets for Apple Silicon and Intel macOS. After cloning, `make bootstrap` detects the architecture, downloads the latest archive and `SHA256SUMS`, verifies it, and hands installation to the Go CLI:

```bash
git clone https://github.com/savioserra/lazyvim.git ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
make bootstrap
```

Installer flags can be passed with `INSTALL_ARGS`, for example `make bootstrap INSTALL_ARGS="--minimal --no-font"`. For later no-Go updates, run `git pull --ff-only` in the clone followed by `make bootstrap`. Other installed lifecycle commands do not need Go; `dotfiles sync` intentionally rebuilds the CLI from pulled source and therefore remains the source-build path.

### Build from source

Linux and macOS:

```bash
git clone https://github.com/savioserra/lazyvim.git ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
make build
.build/dotfiles install
```

Windows (PowerShell):

```powershell
git clone <your-repository-url> "$HOME\Documents\Dev\dotfiles"
Set-Location "$HOME\Documents\Dev\dotfiles"
New-Item -ItemType Directory -Force .build | Out-Null
go build -trimpath -o .build/dotfiles.exe ./cmd/dotfiles
./.build/dotfiles.exe install
```

The installer copies itself into the managed tool directory and installs `dotfiles` and `nvim` launchers. It remembers the repository location, so lifecycle commands work outside the clone. Existing unmanaged targets are moved—not deleted—to timestamped backup directories.

Defaults:

- Unix tools: `~/.local/opt`; launchers: `~/.local/bin`
- Windows tools: `%LOCALAPPDATA%\Programs\dotfiles`
- Unix backups: `~/.local/state/dotfiles/backups/`
- Windows backups: `%LOCALAPPDATA%\dotfiles\state\backups\`

Set `DOTFILES_OPT_HOME` or `DOTFILES_BIN_HOME` to override tool and launcher locations.

Installer options:

```text
--minimal      Install Neovim, chezmoi, the CLI, and configuration only
--no-font      Skip JetBrainsMono Nerd Font
--no-restore   Skip plugins, Mason packages, and Tree-sitter parsers
--offline      Forbid network downloads; requires --no-restore
```

Every archive is cached, SHA-256 verified, safely extracted by Go, and identified by a platform/hash release marker. The CLI no longer depends on curl, jq, tar, unzip, or PowerShell for this work. `dotfiles check` is strict: after a minimal or `--no-restore` installation, run `dotfiles restore` before expecting all lock checks to pass.

## CLI

```bash
dotfiles apply          # apply repository configuration
dotfiles capture        # capture modified managed files
dotfiles restore        # enforce editor, Mason, parser, and tmux locks
dotfiles restore-tmux   # enforce exact tmux plugin commits
dotfiles lock-mason     # snapshot installed Mason versions
dotfiles check          # validate tools, drift, locks, formatting, tmux, startup
dotfiles update         # intentionally update editor locks and parsers
dotfiles sync           # fast-forward pull, install, restore, and check
dotfiles nvim -- --version # run pinned Neovim through the normalized launcher
```

Flags for delegated programs go after `--`; this preserves Cobra help and global flags such as `dotfiles apply --repo <path> -- --dry-run`.

Restore selectors:

```bash
dotfiles restore --plugins-only
dotfiles restore --mason-only
dotfiles restore --skip-parsers
```

Make targets (`make apply`, `make capture`, `make restore`, `make check`, `make update`, and `make sync`) build the CLI when needed and call the same commands.

### Configuration workflow

Edit live files, inspect chezmoi drift, and capture them:

```bash
nvim ~/.config/nvim/lua/config/options.lua
dotfiles apply -- --dry-run
dotfiles capture
git diff
git add .
git commit -m "feat: update development configuration"
```

`sync` and `update` refuse a dirty Git worktree or uncaptured chezmoi drift. To roll back, check out an older commit and run `dotfiles restore`.

## Downloads and offline builds

The installer downloads missing archives automatically. The dedicated command group also exposes cache management:

```bash
dotfiles downloads list --font
dotfiles downloads fetch --font
dotfiles downloads verify --font
dotfiles downloads clean
```

To build a self-contained offline host-tool installer, fetch archives into `bundles/` and rebuild:

```bash
dotfiles downloads bundle --all-platforms --font
make build
.build/dotfiles install --offline --no-restore
```

Offline mode covers the CLI, pinned host tools, font, and chezmoi configuration. Lazy/Mason/Tree-sitter/tmux restoration has its own upstream network requirements and is therefore disabled explicitly with `--no-restore`.

`assets.go` uses `go:embed` for the chezmoi source, manifests, and every file present in `bundles/`. Bundled archives are still checked against `manifests/tools.env` before extraction. Archives are Git-ignored by default because the complete matrix is large; build immediately or explicitly force-add selected release assets.

## Repository layout

```text
.
├── cmd/dotfiles/                 # Cobra executable
├── internal/
│   ├── app/                      # install/apply/restore/check/update orchestration
│   ├── archive/                  # traversal-safe zip/tar.gz/tar.xz extraction
│   ├── atomicfile/               # platform-specific atomic publication
│   ├── buildinfo/                # consistent VCS/release version metadata
│   ├── cli/                      # command tree and injectable app boundary
│   ├── config/                   # declarative manifest/platform catalog
│   ├── download/                 # cache, retries, bundles, SHA-256 verification
│   └── host/                     # injectable native-command execution
├── assets.go                     # go:embed boundary
├── bundles/                      # optional offline release archives
├── home/                         # chezmoi source state
├── manifests/                    # pinned tools and tmux plugin revisions
├── Makefile
└── .github/workflows/ci.yml      # tests, cross-builds, and host validation
```

## Design notes

- Repository commands use an explicit, remembered, or executable-relative checkout; ambient working directories are not trusted. Standalone embedded mode supports install/apply/restore/check but intentionally rejects capture/lock-mason/update/sync.
- The `nvim` launcher is the Go binary invoked under a second name. It normalizes Snap VS Code's revision-specific `XDG_DATA_HOME` before replacing itself with pinned Neovim.
- Release directories include `.dotfiles-release` with platform and archive hash, preventing accidental reuse across architecture migrations.
- Archive extraction rejects absolute paths, traversal, escaping symlinks, hard links, devices, and other special entries.
- Host tool updates remain intentional: change version, URL, and digest together in `manifests/tools.env`, rebuild, install, and check.
