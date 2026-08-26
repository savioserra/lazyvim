# Repository reference

## Path map

| Path | Role |
| --- | --- |
| `README.md` | Install, apply, update commands |
| `AGENTS.md` | Repository-wide implementation rules |
| `tests/capabilities.test.lua` | Fast graph, profile, runner, adapter tests |
| `.github/scripts/test-apply.ps1` | Scratch-home end-to-end apply test |
| `.github/workflows/ci.yml` | Platform matrix and lint |
| `.github/workflows/release.yml` | Tagged source archives |
| `home/` | Chezmoi source root |
| `home/.chezmoiexternals/` | Pinned host downloads |
| `home/.chezmoiscripts/` | Primary post-apply lifecycle entry points |
| `home/dot_local/share/lazyvim/` | Lua runtime, policy, features, versions |
| `home/dot_pi/agent/skills/` | Managed global Pi skills |
| `home/dot_config/nvim/` | Neovim config and locks |
| `home/dot_config/tmux/`, `home/dot_tmux.conf` | tmux config |

## Documentation map

| Document | Scope |
| --- | --- |
| [`capabilities.md`](capabilities.md) | Dependency direction, contracts, lifecycle phases |
| [`chezmoi.md`](chezmoi.md) | Source naming, externals, ignores, removals, scripts |
| [`tools.md`](tools.md) | Managed tool inventory and platform coverage |
| [`secrets.md`](secrets.md) | 1Password boundary, vault scope, Pi skill policy |
| [`nvim.md`](nvim.md) | Editor entry points, profile, plugins, locks |
| [`tmux.md`](tmux.md) | Settings, plugin pins, theme |
| [`lua-migration.md`](lua-migration.md) | Runtime decision record |

## Invariants

- Pinned Neovim is the lifecycle runtime.
- Chezmoi owns deployed files and archive downloads.
- Downloads require SHA-256 checksums.
- Managed tools install under user-local targets only.
- Capability declarations contain policy only.
- Generic runtime modules contain no domain behavior.
- Neovim language composition has one profile source.
- Removed non-`exact` targets are listed in `.chezmoiremove`.
- The retired Go CLI structure (`go.mod`, `cmd/`, `internal/`) must not return.

## Validation layers

| Layer | Command/location |
| --- | --- |
| Lua format | `stylua --check --config-path .stylua.toml ...` |
| Runtime unit/composition | `nvim -l tests/capabilities.test.lua` |
| Chezmoi render | `chezmoi ... apply --dry-run` |
| End to end | `.github/scripts/test-apply.ps1` |
| Platform matrix | `.github/workflows/ci.yml` |
