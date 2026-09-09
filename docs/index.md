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
| [`testing.md`](testing.md) | Offline checks and isolated Linux container E2E recipe |
| [`secrets.md`](secrets.md) | 1Password boundary, vault scope, Pi skill policy |
| [`nvim.md`](nvim.md) | Editor entry points, profile, plugins, locks |
| [`tmux.md`](tmux.md) | Settings, plugin pins, theme |
| [`lua-migration.md`](lua-migration.md) | Runtime rationale and explicitly historical context |
