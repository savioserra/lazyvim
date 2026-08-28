# LazyVim workstation

Chezmoi source state for a pinned Neovim and tmux environment on Linux,
WSL-as-Linux, and macOS. Native Windows is unsupported. Host lifecycle behavior is organized as a workstation package monorepo;
Neovim is one package and remains the temporary Phase 1 Lua launcher.

## Support

| Host | Architectures | Notes |
| --- | --- | --- |
| Linux | x86_64 | WSL is Linux |
| macOS | arm64, x86_64 | tmux and Git required |

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
workstation/apps/cli/run.lua setup
workstation/apps/cli/run.lua sync
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
| Shared host versions | `home/dot_local/share/workstation/versions.json` |
| Node version | `home/dot_node-version` |
| Global pi package | `versions.json` and `packages/pi/init.lua` |
| Global Pi skills | `home/dot_pi/private_agent/skills/`; secret operations require explicit `/skill:secrets` invocation |
| Registry Pi extension packages | Exact versions and integrity in `versions.json`; lifecycle under `packages/pi-subagents/` |
| Source-managed Pi extensions | `home/dot_pi/private_agent/extensions/`; owning workstation package verifies discovery and compatibility |
| Tmux subagent TUI | Existing authoritative `pi-subagents`/XState observer plus separately gated hosted-owned tmux runtime |
| GoAkt subagents service | Nested `services/subagents/` module, inert hosted bridge, and private config with service/hosted execution disabled; no service is installed or started |
| Neovim plugins | `home/dot_config/nvim/lazy-lock.json` |
| Mason packages | `home/dot_config/nvim/mason-lock.json` |
| Tree-sitter parsers | `lua/plugins/treesitter.lua` and locked nvim-treesitter commit |
| Neovim language composition | `home/dot_config/nvim/lua/languages/profile.lua` |
| Workstation package contributions | `home/dot_local/share/workstation/packages/` |
| Package ordering | `home/dot_local/share/workstation/lua/workstation/catalog.lua` |
| Generic lifecycle core | `home/dot_local/share/workstation/lua/workstation/core/` |
| tmux plugin commits | `home/dot_local/share/packages/tmux/init.lua` |

Chezmoi itself is installed independently and pinned by `home/.chezmoiversion`.
System prerequisites such as tmux and Git are not provisioned by this repository.

## Update rules

| Change | Files |
| --- | --- |
| Host tool | Version catalog, owning external URL/checksum, `docs/tools.md` |
| Node | `.node-version`, Node external URL/checksum |
| pi coding agent | Version/integrity catalog and `packages/pi/init.lua` |
| Pi extension package | Exact version/integrity, package lifecycle verification, `docs/capabilities.md` |
| Pi skill | `home/dot_pi/private_agent/skills/<name>/SKILL.md`, capability inventory, discovery verification |
| Neovim plugin | Plugin spec and `lazy-lock.json` |
| Mason package | Neovim/profile config and `mason-lock.json` |
| tmux plugin | `packages/tmux/init.lua`, `docs/tmux.md` |

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
    ├── dot_local/share/workstation/  lifecycle package monorepo and tmux actor capability
    ├── dot_pi/private_agent/extensions/      source-managed Pi extensions
    ├── dot_pi/private_agent/skills/          global Pi skills
    └── dot_tmux.conf                 tmux configuration
```

## Documentation

| Document | Reference |
| --- | --- |
| Repository map and invariants | [`docs/index.md`](docs/index.md) |
| Chezmoi apply and scripts | [`docs/chezmoi.md`](docs/chezmoi.md) |
| Capability/runtime boundaries | [`docs/capabilities.md`](docs/capabilities.md) |
| Managed tools | [`docs/tools.md`](docs/tools.md) |
| Secrets and 1Password | [`docs/secrets.md`](docs/secrets.md) |
| Neovim | [`docs/nvim.md`](docs/nvim.md) |
| tmux | [`docs/tmux.md`](docs/tmux.md) |
| Runtime decision | [`docs/lua-migration.md`](docs/lua-migration.md) |

## CI and release

- `.github/workflows/ci.yml`: supported Linux/macOS jobs; WSL follows Linux.
- `.github/scripts/test-apply.sh`: extracted Linux/macOS scratch-apply validation. The retired PowerShell/native-Windows lifecycle is not supported.
- `.github/workflows/release.yml`: `vMAJOR.MINOR.PATCH` source archives and SHA-256 sums.
- `home/dot_pi/private_agent/extensions/tmux-subagents/`: supervised XState actors, adapters, authenticated IPC, and the separate Terminal Kit renderer; enablement remains an explicit apply/reload gate.
