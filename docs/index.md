# Repository reference

## Path map

| Path | Role |
| --- | --- |
| `README.md` | Install, apply, update commands |
| `AGENTS.md` | Repository-wide implementation rules |
| `tests/capabilities.test.lua` | Fast graph, profile, runner, adapter tests |
| `tests/tmux-subagents/` | Mirrored actor, OTP supervisor, RPC, projection, IPC, renderer, ticket, and isolated tmux tests |
| `services/subagents/` | Sole nested Go service module, canonical protobuf contract, direct GoAkt actors, and daemon spike tests |
| `.github/scripts/test-apply.ps1` | Scratch-home end-to-end apply test |
| `.github/workflows/ci.yml` | Platform matrix and lint |
| `.github/workflows/release.yml` | Tagged source archives |
| `home/` | Chezmoi source root |
| `home/.chezmoiexternals/` | Pinned host downloads |
| `home/.chezmoiscripts/` | Primary post-apply lifecycle entry points |
| `home/dot_local/share/workstation/` | Package monorepo, lifecycle CLI, core, and versions |
| `home/dot_pi/private_agent/skills/` | Managed global Pi skills |
| `home/dot_pi/private_agent/extensions/` | Source-managed Pi extensions |
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
| [`subagents.md`](subagents.md) | GoAkt service boundary, protocol, security, platform inventory, test policy, and links to canonical subagents ADRs |
| [`architecture/subagents/`](architecture/subagents/) | Accepted direct-GoAkt, global-agent/hosted-Pi, routing, transport, persistence, and diagnostics decisions |

## Invariants

- Pinned Neovim is the temporary Phase 1 Lua launcher; Neovim is a lifecycle package.
- Chezmoi owns deployed files and archive downloads.
- Downloads require SHA-256 checksums.
- Managed tools install under user-local targets only.
- Each package contributes capability metadata and lifecycle behavior through one registered record.
- Generic core modules contain no domain behavior and import no packages.
- Neovim language composition has one profile source.
- `pi-subagents` remains authoritative; tmux panes consume bounded observer projections only.
- Removed non-`exact` targets are listed in `.chezmoiremove`.
- The retired root Go CLI structure must not return; the only approved nested module is `services/subagents/`.
- Supported hosts are Linux, WSL-as-Linux, and macOS. Retained native-Windows files are removal inventory.
- Reusable global AgentActors outlive ephemeral Pi sessions; session cleanup cannot stop agent work.

## Validation layers

| Layer | Command/location |
| --- | --- |
| Lua format | `stylua --check --config-path .stylua.toml ...` |
| Runtime unit/composition | `nvim -l tests/capabilities.test.lua` |
| Chezmoi render | `chezmoi ... apply --dry-run` |
| End to end | `.github/scripts/test-apply.ps1` |
| Platform matrix | `.github/workflows/ci.yml` |
