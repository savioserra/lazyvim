# Repository reference

## Path map

| Path | Role |
| --- | --- |
| `README.md` | Install, apply, update commands |
| `AGENTS.md` | Repository-wide implementation rules |
| `tests/*.test.lua` | Graph/profile, provider contract, journal/preconditions, real backend renders, provisioning, CLI/update/launcher, cold bootstrap, package parity and isolated harness fixtures |
| `.github/scripts/test-apply.sh` | Scratch-home end-to-end apply test |
| `.github/workflows/ci.yml` | Platform matrix and lint |
| `.github/workflows/release.yml` | Tagged source archives |
| `workstation/packages/`, `workstation/versions.json` | Package-owned host provisioning, file recipes, payload assets and canonical pins |
| `workstation/bin/workstation` | Sole public lifecycle launcher; bootstrap installs the home symlink |
| `workstation/` | Package monorepo, lifecycle CLI, core, providers, engine state and versions |

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
| [`herdr.md`](herdr.md) | Pinned Herdr binary and official Pi hook, ownership and compatibility gates |
| [`lua-migration.md`](lua-migration.md) | Runtime rationale and explicitly historical context |
