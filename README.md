# Neovim dotfiles

A package-oriented dotfiles monorepository for installing, maintaining, and synchronizing this LazyVim setup on Linux, macOS, and Windows. It captures the configuration, editor binary, companion CLI tools, plugin revisions, Mason package versions, and Nerd Font without committing generated runtime data.

## What is reproducible

| Layer | Source of truth |
| --- | --- |
| Neovim, ripgrep, fd, fzf, lazygit, tree-sitter CLI, font | `manifests/tools.env` (platform assets, URLs, SHA-256) |
| LazyVim and Neovim plugins | `packages/nvim/lazy-lock.json` |
| LSP servers, formatters, linters, and debuggers | `packages/nvim/mason-lock.json` |
| Tree-sitter parsers | parser revisions supplied by the locked `nvim-treesitter` plugin |
| Configuration | `packages/nvim/` |

Generated plugins, tools, logs, caches, undo data, sessions, and editor history remain in the platform-standard Neovim data/state/cache directories and are rebuilt from the repository.

## Supported hosts

| Platform | Architectures | Installer |
| --- | --- | --- |
| Linux | x86_64 | Bash: `scripts/install-linux` |
| macOS | Apple Silicon and Intel | Bash: `scripts/install-macos` |
| Windows 10/11 | ARM64 and x64 | PowerShell: `scripts/install-windows.ps1` |

Intel macOS uses fd 10.3.0 because fd stopped publishing Intel macOS binaries after that release. Other supported platforms use fd 10.4.2.

### Host prerequisites

All platforms need Git, a C compiler for Tree-sitter/native code, Node.js/npm, and Go for the configured Mason packages.

Ubuntu/Zorin:

```bash
sudo apt install build-essential curl git jq unzip xz-utils xclip inotify-tools fontconfig
```

macOS:

```bash
xcode-select --install
brew install git jq node go
```

Windows—install Git, Node.js, Go, and a compiler such as LLVM/MSVC. For example:

```powershell
winget install --id Git.Git
winget install --id OpenJS.NodeJS.LTS
winget install --id GoLang.Go
winget install --id LLVM.LLVM
```

Restart the terminal after installing prerequisites so their updated `PATH` is visible.

## Install on Linux

```bash
git clone <your-repository-url> ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
./scripts/install-linux
```

## Install on macOS

```bash
git clone <your-repository-url> ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
./scripts/install-macos
```

`scripts/install` remains a convenience dispatcher that selects one of those explicit entry points. Both use the shared `scripts/lib/install-unix.sh` engine and install into `~/.local/opt`, `~/.local/bin`, and `~/.config/nvim`. macOS fonts go to `~/Library/Fonts`; Linux fonts use the XDG data directory.

Existing targets are moved—not deleted—to:

```text
~/.local/state/dotfiles/backups/<UTC timestamp>/
```

Ensure `~/.local/bin` is in `PATH`. Set `DOTFILES_OPT_HOME` or `DOTFILES_BIN_HOME` before installation to override the binary locations.

## Install on Windows

Run PowerShell—not Git Bash:

```powershell
git clone <your-repository-url> "$HOME\Documents\Dev\dotfiles"
Set-Location "$HOME\Documents\Dev\dotfiles"
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-windows.ps1
```

The Windows installer:

- installs tools under `%LOCALAPPDATA%\Programs\dotfiles`;
- creates command shims and adds their directory to the user `PATH`;
- junctions `%LOCALAPPDATA%\nvim` to `packages\nvim`;
- keeps generated data under `%LOCALAPPDATA%\nvim-data`;
- installs the Nerd Font for the current user without requiring administrator rights.

Existing configuration is moved to:

```text
%LOCALAPPDATA%\dotfiles\state\backups\<UTC timestamp>\
```

If junction creation fails, enable **Windows Developer Mode** or keep the repository and `%LOCALAPPDATA%` on compatible local volumes.

## What every installer does

1. Selects the release asset for the host OS and CPU architecture.
2. Verifies its committed SHA-256 before extraction.
3. Safely links the live Neovim configuration to this repository.
4. Restores plugins and Mason tools at locked versions.
5. Installs missing Tree-sitter parsers.

Use `--minimal --no-restore` with the Linux/macOS entry points or `-Minimal -NoRestore` with the Windows entry point for a configuration-only installation without companion tools.

## Daily maintenance

Linux/macOS:

```bash
make check       # syntax, JSON, Stylua, lock versions, startup
make restore     # enforce both lockfiles after a rollback or pull
make lock-mason  # snapshot currently installed Mason versions
make update      # intentionally update plugins, Mason tools, and parsers
```

Windows:

```powershell
.\scripts\check.ps1
.\scripts\restore.ps1
.\scripts\lock-mason.ps1
.\scripts\update.ps1
```

Updates require a clean worktree and leave lockfile changes for review. Test them, inspect `git diff`, then commit and push. To roll back, restore an older Git commit and run the platform restore command.

Host-side binaries deliberately stay outside the automatic update command. Change the matching version, release URLs, and SHA-256 values together in `manifests/tools.env`, rerun the installer, and verify with the check command.

## Synchronize machines

Create a private or public remote, then publish the initial branch:

```bash
git remote add origin <your-repository-url>
git push -u origin main
```

Linux/macOS:

```bash
make sync
```

Windows:

```powershell
.\scripts\sync.ps1
```

Sync refuses a dirty worktree, performs a fast-forward-only pull, reapplies links, restores the lockfiles, and runs checks. Configuration changes should be committed and pushed normally with Git.

## Repository layout

```text
.
├── manifests/tools.env       # cross-platform release artifacts and hashes
├── packages/bin/nvim         # Linux/macOS portable wrapper
├── packages/nvim/            # complete Neovim configuration
├── scripts/install-linux     # Linux release selection
├── scripts/install-macos     # macOS/architecture release selection
├── scripts/install-windows.ps1 # native Windows installation
├── scripts/lib/              # shared Unix and PowerShell primitives
├── scripts/                  # restore/update/check/sync lifecycle
├── docs/setup-analysis.md    # findings from the original machine
├── docs/code-review.md       # installer critique and remaining constraints
└── .github/workflows/ci.yml  # Linux/macOS/Windows headless validation
```

## Design references

The workflow follows the official recommendations to keep `lazy-lock.json` in version control and use `:Lazy restore` across machines. Mason has versioned installs but no core lockfile, so this repository records versions from Mason receipts and restores them through its official `:MasonInstall package@version` interface.

- [lazy.nvim lockfile](https://lazy.folke.io/usage/lockfile)
- [LazyVim installation](https://www.lazyvim.org/installation)
- [mason.nvim documentation](https://github.com/mason-org/mason.nvim/blob/main/doc/mason.txt)
- [Neovim standard paths](https://neovim.io/doc/user/starting.html#standard-path)
- [Neovim installation](https://neovim.io/doc/install/)
