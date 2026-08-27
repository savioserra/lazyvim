# Repository instructions

## Goal

Maintain a reproducible chezmoi source state for Neovim and tmux on Linux,
macOS, and Windows.

## Read first

| Area | Reference |
| --- | --- |
| Repository map | `docs/index.md` |
| Chezmoi apply/scripts | `docs/chezmoi.md` |
| Capability boundaries | `docs/capabilities.md` |
| Neovim | `docs/nvim.md` |
| tmux | `docs/tmux.md` |
| Secrets | `docs/secrets.md` |
| Managed tools | `docs/tools.md` |

Use the nearest `AGENTS.md` for scoped rules.

## Architecture rules

- Define each lifecycle capability once under `home/dot_local/share/workstation/packages/`.
- Keep `workstation/core/` domain-neutral. It must not import the catalog, packages, or Neovim.
- Register each package once in the explicit ordered `workstation/catalog.lua`; do not auto-discover packages.
- Keep complex behavior and feature-specific OS branches inside the owning package.
- Let the core materializer explicitly split graph specifications from lifecycle handlers; do not deep-merge contributions.
- Keep Neovim language composition in `lua/languages/profile.lua`, not in lifecycle capabilities.
- Keep chezmoi as the archive/file provisioner and public apply/update interface.
- Invoke setup and sync from `home/.chezmoiscripts/`; do not add repository-level wrappers.
- Keep Lua `setup` limited to post-apply host state; keep `sync` limited to mutable application state.
- Keep `pi-subagents` authoritative for managed runs; tmux observer integrations may consume only documented RPC/events and bounded projections.
- Adopt existing tmux panes only through cooperative foreground claims; never automate `send-keys` or `respawn-pane` into user panes.
- Do not add Node as a bootstrap dependency; pinned Neovim is the lifecycle runtime until the standalone workstation runtime replaces it.

## Required checks

Run checks relevant to the change. Before completion, run all available fast checks:

```bash
nvim -l tests/capabilities.test.lua
npm ci --omit=dev --ignore-scripts --prefix home/dot_pi/private_agent/extensions/tmux-subagents
find tests/tmux-subagents -name '*.test.ts' -print0 | xargs -0 node --test
stylua --check --config-path .stylua.toml home/dot_local/share/workstation home/dot_config/nvim tests
git diff --check
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

On Windows, use the managed StyLua command under
`%LOCALAPPDATA%\nvim-data\mason\bin\stylua.cmd` when `stylua` is not on `PATH`.

Full platform verification is performed by `.github/scripts/test-apply.ps1`.
It calls chezmoi against a scratch home, lets post-apply scripts run setup/sync,
formats, runs runtime tests, and executes `run.lua verify`.

## Change rules

| Change | Required updates |
| --- | --- |
| Host tool version | `versions.json`, owning external URL/checksum, `docs/tools.md` |
| Node version | `home/dot_node-version`, Node external URL/checksum |
| Global npm capability | Exact version, registry integrity, feature setup/verify, docs |
| Pi extension package | Exact version or source-managed extension contract, setup/verify, Pi discovery, docs |
| Pi skill | `home/dot_pi/private_agent/skills/<name>/SKILL.md`, `pi-skills` verification, docs |
| Standalone TUI bundle | Exact source versions/checksums, reproducible bundle CI, licenses/SBOM, external only after release hashes exist |
| tmux plugin pin | `packages/tmux/init.lua`, `docs/tmux.md` |
| Workstation package | combined contribution, package catalog, tests, docs |
| Neovim language | `languages/profile.lua`, lockfiles if needed, behavior case |
| Removed deployed source | `home/.chezmoiremove` unless inside an `exact` target |
| New platform condition | external template, capability support, feature backend, CI/test coverage |

## Do not

- Recreate the retired Go CLI, `go.mod`, `internal/`, `cmd/`, or a Makefile.
- Install managed tools with `sudo` or an OS package manager.
- Add unpinned downloads.
- Duplicate LazyVim language imports outside `languages/profile.lua`.
- Put feature workflows in `setup/platforms/`.
- Commit generated plugin, Mason, parser, cache, session, or history state.
- Add shell or PowerShell wrappers around `chezmoi apply` or `chezmoi update`.
