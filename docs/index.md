# Repository reference

## Path map

| Path | Role |
| --- | --- |
| `README.md` | Install, apply, update commands |
| `AGENTS.md` | Repository-wide implementation rules |
| `tests/*.test.lua` | Graph/profile, provisioning, CLI/update/launcher, cold bootstrap, package parity and isolated harness fixtures |
| `.github/scripts/test-apply.sh` | Scratch-home end-to-end apply test |
| `.github/workflows/ci.yml` | Platform matrix and lint |
| `.github/workflows/release.yml` | Tagged source archives |
| `chezmoi/` | Chezmoi source root |
| `workstation/packages/`, `workstation/versions.json` | Package-owned host provisioning and canonical pins |
| `workstation/bin/workstation` | Sole public lifecycle launcher; bootstrap installs the home symlink |
| `workstation/` | Package monorepo, lifecycle CLI, core, and versions |
| `chezmoi/dot_pi/private_agent/skills/` | Managed global Pi skills |
| `chezmoi/dot_pi/private_agent/extensions/` | Source-managed Pi extensions |
| `chezmoi/dot_config/nvim/` | Neovim config and locks |
| `chezmoi/dot_config/tmux/`, `chezmoi/dot_tmux.conf` | tmux config |

## Documentation map

| Document | Scope |
| --- | --- |
| [`capabilities.md`](capabilities.md) | Dependency direction, contracts, lifecycle phases |
| [`chezmoi.md`](chezmoi.md) | Subordinate file backend, isolation, removals and guarded cutover |
| [`tools.md`](tools.md) | Managed tool inventory and platform coverage |
| [`secrets.md`](secrets.md) | 1Password boundary, vault scope, Pi skill policy |
| [`nvim.md`](nvim.md) | Editor entry points, profile, plugins, locks |
| [`tmux.md`](tmux.md) | Settings, plugin pins, theme |
| [`lua-migration.md`](lua-migration.md) | Runtime decision record |

## Invariants

- Engine bootstrap installs pinned Neovim as the Lua host, the pinned backend and the public launcher. No Node/system-Neovim prerequisite.
- The whole Git clone contains sibling `workstation/` and `chezmoi/`; it is never a deployed engine mirror.
- Apply owns retirement/files/Node refresh/setup; sync is separate; update checks pull/bootstrap/apply/sync/verify.
- Chezmoi owns deployed home files; engine bootstrap and package setup own archive downloads.
- Downloads require SHA-256 checksums.
- Managed tools install under user-local targets only.
- Each package contributes capability metadata and lifecycle behavior through one registered record.
- Generic core modules contain no domain behavior and import no packages.
- Neovim language composition has one profile source.
- Removed non-`exact` targets are listed in `.chezmoiremove`.
- The retired root Go CLI structure and nested Go service modules must not return.
- Supported hosts are Linux, WSL-as-Linux, and macOS (arm64).

## Validation layers

| Layer | Command/location |
| --- | --- |
| Lua format | `stylua --check --config-path .stylua.toml ...` |
| Runtime/synthetic fixtures | Pinned `nvim -l tests/<suite>.test.lua` for every suite |
| Shell/Lua/JSON/projection | `.github/scripts/check.sh` (after managed sync); each shell checked individually |
| File-only render | Inspected isolated backend probe in `chezmoi.md`; not lifecycle acceptance |
| End to end | `.github/scripts/test-apply.sh` |
| Platform matrix | `.github/workflows/ci.yml` |
