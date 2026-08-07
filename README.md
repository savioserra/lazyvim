# Cross-platform development dotfiles

A chezmoi-managed dotfiles repository for reproducing this Neovim and tmux setup on Linux, macOS, and Windows. It pins the editor, companion CLI tools, plugins, Mason packages, Tree-sitter parsers, and Nerd Font while keeping generated runtime data out of Git.

## What is reproducible

| Layer | Source of truth |
| --- | --- |
| Neovim, chezmoi, ripgrep, fd, fzf, lazygit, tree-sitter CLI, font | `manifests/tools.env` |
| LazyVim and Neovim plugins | `home/dot_config/nvim/lazy-lock.json` |
| LSP servers, formatters, linters, and debuggers | `home/dot_config/nvim/mason-lock.json` |
| Tree-sitter parsers | Revisions supplied by the locked `nvim-treesitter` plugin |
| Neovim configuration | `home/dot_config/nvim/` |
| tmux extensions | `manifests/tmux-plugins.lock` |
| tmux configuration and tmux2k theme | `home/dot_tmux.conf` and `home/dot_config/tmux/themes/tmux2k.conf` |
| Target-file mapping and host conditions | `.chezmoiroot` and `home/.chezmoiignore` |

Chezmoi applies Neovim to `~/.config/nvim` and tmux to `~/.tmux.conf`. On native Windows, tmux is ignored and `%LOCALAPPDATA%\nvim` is junctioned to the chezmoi-managed configuration under the user profile.

The tmux status bar uses tmux2k's built-in Catppuccin palette with session, Git, working-directory, CPU, memory, and clock segments. High-contrast text replaces utilization gradients, and uptime is omitted to avoid a clock-like duplicate. TPM, tmux2k, tmux-fingers, and tmux-yank are restored to exact commits from `manifests/tmux-plugins.lock`.

Generated plugins, tools, logs, caches, undo data, sessions, editor history, and tmux session state remain in platform-standard data/state/cache directories.

## Supported hosts

| Platform | Architectures | Installer |
| --- | --- | --- |
| Linux | x86_64 | `scripts/install-linux` |
| macOS | Apple Silicon and Intel | `scripts/install-macos` |
| Windows 10/11 | ARM64 and x64 | `scripts/install-windows.ps1` |

WSL is treated as Linux and receives the tmux configuration. Linux ARM64 and other operating systems are not currently included in the pinned asset matrix. Intel macOS uses fd 10.3.0 because newer releases no longer publish Intel macOS binaries.

### Host prerequisites

All platforms need Git, a C compiler, Node.js/npm, and Go for configured Mason packages. Linux and macOS also need tmux 3.2 or newer and Bash 5.2 or newer for the managed tmux2k status bar.

Ubuntu/Zorin:

```bash
sudo apt install build-essential curl git jq unzip xz-utils xclip inotify-tools fontconfig tmux nodejs npm golang-go
```

macOS:

```bash
xcode-select --install
brew install bash git jq node go tmux
```

Windows—install Git, Node.js, Go, and LLVM/MSVC. Use PowerShell, not Git Bash:

```powershell
winget install --id Git.Git
winget install --id OpenJS.NodeJS.LTS
winget install --id GoLang.Go
winget install --id LLVM.LLVM
```

Restart the terminal after installing prerequisites so its `PATH` is current. Jest integration additionally expects `yarn` in projects that use it.

## Install

The clone location is arbitrary, but keep the clone in place because lifecycle commands use it as the chezmoi source repository.

Linux:

```bash
git clone <your-repository-url> ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
./scripts/install-linux
```

macOS:

```bash
git clone <your-repository-url> ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
./scripts/install-macos
```

`scripts/install` dispatches to the correct Unix installer. By default, pinned tools go under `~/.local/opt`, command links under `~/.local/bin`, and managed configuration under the home directory. Set `DOTFILES_OPT_HOME` or `DOTFILES_BIN_HOME` to override binary locations.

Windows:

```powershell
git clone <your-repository-url> "$HOME\Documents\Dev\dotfiles"
Set-Location "$HOME\Documents\Dev\dotfiles"
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-windows.ps1
```

Windows tools go under `%LOCALAPPDATA%\Programs\dotfiles`; command shims are added to the user `PATH`. If junction creation fails, enable Windows Developer Mode or keep the repository and `%LOCALAPPDATA%` on compatible local volumes.

Existing unmanaged targets are moved—not deleted—to timestamped directories:

- Unix: `~/.local/state/dotfiles/backups/<UTC timestamp>/`
- Windows: `%LOCALAPPDATA%\dotfiles\state\backups\<UTC timestamp>\`

Installer options:

- Unix: `--minimal`, `--no-font`, `--no-restore`
- Windows: `-Minimal`, `-NoFont`, `-NoRestore`

Every installer selects platform assets, verifies committed SHA-256 values, installs pinned chezmoi, and applies configuration. Unless restore is disabled, it also restores the Neovim, Mason, and tmux plugin locks and installs missing Tree-sitter parsers.

## Configuration workflow

Chezmoi keeps the repository source state and live files synchronized deliberately rather than through permanent repository symlinks.

Edit live files, then capture them into the repository:

```bash
nvim ~/.config/nvim/lua/config/options.lua
nvim ~/.tmux.conf
chezmoi --source "$PWD" diff
make capture

git diff
git add .
git commit -m "feat: update development configuration"
git push
```

Apply repository changes to the live files:

```bash
make apply
```

Windows equivalents:

```powershell
.\scripts\capture.ps1
.\scripts\apply.ps1
```

You can also use chezmoi directly from the repository:

```bash
chezmoi --source "$PWD" diff
chezmoi --source "$PWD" --destination "$HOME" apply
chezmoi --source "$PWD" --destination "$HOME" re-add
```

Review the source/target changes with `chezmoi --source "$PWD" diff` before capture, then review `git diff` before committing. Do not add credentials, API tokens, private keys, shell history, editor state, or tmux session state as ordinary files; use chezmoi encryption or a supported password manager if secrets are added later.

## Maintenance

Linux/macOS:

```bash
make apply       # apply repository configuration to the home directory
make capture     # capture modified managed files into the repository
make check       # syntax, versions, chezmoi drift, formatting, tmux, startup
make restore     # apply configuration and enforce Neovim, Mason, and tmux locks
make restore-tmux # restore exact TPM/tmux2k/extension revisions
make lock-mason  # snapshot installed Mason versions and capture the lockfile
make update      # intentionally update plugins, Mason tools, and parsers
make sync        # fast-forward pull, apply, restore, and check
```

Windows:

```powershell
.\scripts\apply.ps1
.\scripts\capture.ps1
.\scripts\check.ps1
.\scripts\restore.ps1
.\scripts\lock-mason.ps1
.\scripts\update.ps1
.\scripts\sync.ps1
```

`sync` and `update` refuse a dirty Git worktree. Capture and commit live configuration changes before synchronizing. To roll back, restore an older Git commit and run `make restore` or `scripts\restore.ps1`.

Host binary updates remain intentional: change each version, platform URL, and SHA-256 together in `manifests/tools.env`, rerun the installer, and run checks. For tmux extension updates, replace the corresponding commit in `manifests/tmux-plugins.lock`, then run `make restore-tmux` and `make check`; TPM updates that are not recorded in the lockfile are deliberately rejected.

## Repository layout

```text
.
├── .chezmoiroot              # points chezmoi at home/
├── home/                     # chezmoi source state
│   ├── .chezmoiignore        # native-Windows tmux exclusion
│   ├── dot_config/nvim/      # maps to ~/.config/nvim
│   ├── dot_config/tmux/      # tmux2k status theme and extension layout
│   └── dot_tmux.conf         # maps to ~/.tmux.conf
├── manifests/tools.env       # pinned cross-platform artifacts and hashes
├── manifests/tmux-plugins.lock # exact tmux extension revisions
├── packages/bin/nvim         # portable Linux/macOS launcher
├── scripts/                  # install/apply/capture/restore/update/check/sync
├── docs/                     # original analysis and installer review
└── .github/workflows/ci.yml  # Linux/macOS/Windows validation
```

## Design references

- [chezmoi source state](https://www.chezmoi.io/reference/concepts/)
- [chezmoi daily operations](https://www.chezmoi.io/user-guide/daily-operations/)
- [lazy.nvim lockfile](https://lazy.folke.io/usage/lockfile)
- [LazyVim installation](https://www.lazyvim.org/installation)
- [mason.nvim documentation](https://github.com/mason-org/mason.nvim/blob/main/doc/mason.txt)
- [Neovim standard paths](https://neovim.io/doc/user/starting.html#standard-path)
- [tmux2k configuration](https://github.com/2KAbhishek/tmux2k)
- [Tmux Plugin Manager](https://github.com/tmux-plugins/tpm)
