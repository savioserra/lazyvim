# LazyVim workstation

Chezmoi source state for a pinned Neovim and tmux environment on Linux, macOS,
and Windows.

## Support

| Host | Architectures | Notes |
| --- | --- | --- |
| Linux | x86_64 | WSL is Linux |
| macOS | arm64, x86_64 | tmux and Git required |
| Windows 10/11 | arm64, x86_64 | tmux excluded |

Unix prerequisites:

```bash
# Ubuntu/Zorin
sudo apt install tmux git

# macOS
xcode-select --install
brew install tmux git
```

Required tmux version: 3.2+. Required Bash version for tmux2k: 5.2+.

## Install

```bash
# Linux/macOS
sh -c "$(curl -fsLS https://get.chezmoi.io)" -- \
  -b "$HOME/.local/bin" -t v2.72.0 -- \
  init --apply savioserra/lazyvim
```

```powershell
# Windows
choco install chezmoi --version=2.72.0 -y
chezmoi init --apply savioserra/lazyvim
```

`init --apply` installs host tools, runs post-apply setup, and restores Neovim
plugins, Mason packages, and Tree-sitter parsers.

## Apply and update

```bash
chezmoi update   # pull the managed source and apply it
chezmoi apply    # apply the current managed source
chezmoi diff     # preview target changes
chezmoi re-add   # capture target edits into source state
```

From a separate repository checkout:

```bash
chezmoi --source "$PWD" apply
```

Chezmoi `run_after` scripts are the lifecycle entry points. Every apply runs:

```text
run.lua setup
run.lua sync
```

No repository-level sync wrapper is required.

```text
:Lazy restore
:MasonLockRestore
:TSUpdate
```

## Reproducibility sources

| State | Source of truth |
| --- | --- |
| Host downloads | `home/.chezmoiexternals/*.toml.tmpl` |
| Shared host versions | `home/dot_local/share/lazyvim/versions.json` |
| Node version | `home/dot_node-version` |
| Neovim plugins | `home/dot_config/nvim/lazy-lock.json` |
| Mason packages | `home/dot_config/nvim/mason-lock.json` |
| Tree-sitter parsers | `lua/plugins/treesitter.lua` and locked nvim-treesitter commit |
| Neovim language composition | `home/dot_config/nvim/lua/languages/profile.lua` |
| Capability policy | `home/dot_local/share/lazyvim/lua/setup/capabilities/` |
| Lifecycle implementation | `home/dot_local/share/lazyvim/lua/setup/features/` |
| tmux plugin commits | `home/dot_local/share/lazyvim/lua/setup/features/tmux.lua` |

Chezmoi itself is installed independently and pinned by `home/.chezmoiversion`.
System prerequisites such as tmux and Git are not provisioned by this repository.

## Update rules

| Change | Files |
| --- | --- |
| Host tool | Version catalog, owning external URL/checksum, `docs/tools.md` |
| Node | `.node-version`, Node external URL/checksum |
| Neovim plugin | Plugin spec and `lazy-lock.json` |
| Mason package | Neovim/profile config and `mason-lock.json` |
| tmux plugin | `setup/features/tmux.lua`, `docs/tmux.md` |

See `AGENTS.md` for implementation constraints and required checks.

## Layout

```text
.
├── AGENTS.md                         contributor and agent rules
├── docs/                             reference documentation
├── tests/                            capability/runtime tests
├── .github/                          CI, release, scratch-home test harness
└── home/                             chezmoi source root
    ├── .chezmoiexternals/            pinned download inventory
    ├── .chezmoiscripts/              primary post-apply lifecycle entry points
    ├── dot_config/nvim/              Neovim configuration and locks
    ├── dot_config/tmux/              tmux theme
    ├── dot_local/share/lazyvim/      lifecycle runtime
    └── dot_tmux.conf                 tmux configuration
```

## Documentation

| Document | Reference |
| --- | --- |
| Repository map and invariants | [`docs/index.md`](docs/index.md) |
| Chezmoi apply and scripts | [`docs/chezmoi.md`](docs/chezmoi.md) |
| Capability/runtime boundaries | [`docs/capabilities.md`](docs/capabilities.md) |
| Managed tools | [`docs/tools.md`](docs/tools.md) |
| Neovim | [`docs/nvim.md`](docs/nvim.md) |
| tmux | [`docs/tmux.md`](docs/tmux.md) |
| Runtime decision | [`docs/lua-migration.md`](docs/lua-migration.md) |

## CI and release

- `.github/workflows/ci.yml`: Linux, macOS arm64/x86_64, Windows.
- `.github/scripts/test-apply.ps1`: scratch-home apply, lifecycle scripts, format, tests, verify.
- `.github/workflows/release.yml`: `vMAJOR.MINOR.PATCH` source archives and SHA-256 sums.
