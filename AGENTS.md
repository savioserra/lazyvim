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

- Keep `setup/capabilities/` declarative. Capability files contain data only.
- Keep `setup/runtime/` domain-neutral. It must not import capabilities or features.
- Pair capability policy with feature handlers only in `setup/app.lua` and the two catalogs.
- Put lifecycle behavior in `setup/features/`.
- Put feature-specific OS branches under that feature; do not widen the global platform adapter.
- Keep Neovim language composition in `lua/languages/profile.lua`, not in lifecycle capabilities.
- Keep chezmoi as the archive/file provisioner and public apply/update interface.
- Invoke setup and sync from `home/.chezmoiscripts/`; do not add repository-level wrappers.
- Keep Lua `setup` limited to post-apply host state; keep `sync` limited to mutable application state.
- Do not add Node as a bootstrap dependency; pinned Neovim is the Lua runtime.

## Required checks

Run checks relevant to the change. Before completion, run all available fast checks:

```bash
nvim -l tests/capabilities.test.lua
stylua --check --config-path .stylua.toml home/dot_local/share/lazyvim home/dot_config/nvim tests
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
| Pi extension package | Exact version, registry integrity, feature setup/verify, Pi discovery, docs |
| Pi skill | `home/dot_pi/agent/skills/<name>/SKILL.md`, `pi-skills` verification, docs |
| tmux plugin pin | `setup/features/tmux.lua`, `docs/tmux.md` |
| Capability | declaration, capability catalog, feature handler, feature catalog, tests, docs |
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
