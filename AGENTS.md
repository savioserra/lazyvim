# Repository instructions

## Goal

Maintain a reproducible chezmoi source state for Neovim and tmux on Linux,
WSL-as-Linux, and macOS (arm64).

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
- Do not add Node as a bootstrap dependency; pinned Neovim is the lifecycle runtime until the standalone workstation runtime replaces it.
- Do not add Go service modules, daemons, or actor runtimes to this repository; the Go toolchain exists only for the Neovim language profile.

## Required checks

Run checks relevant to the change. Before completion, run all available fast checks:

```bash
nvim -l tests/capabilities.test.lua
stylua --check --config-path .stylua.toml home/dot_local/share/workstation home/dot_config/nvim tests
git diff --check
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

Full supported-platform verification runs on Linux/WSL and macOS (arm64).

## Change rules

| Change | Required updates |
| --- | --- |
| Host tool version | `versions.json`, owning external URL/checksum, `docs/tools.md` |
| Node version | `home/dot_node-version`, Node external URL/checksum |
| Global npm capability | Exact version, registry integrity, feature setup/verify, docs |
| Pi extension package | Exact version or source-managed extension contract, setup/verify, Pi discovery, docs |
| Pi skill | `home/dot_pi/private_agent/skills/<name>/SKILL.md`, `pi-skills` verification, docs |
| tmux plugin pin | `packages/tmux/init.lua`, `docs/tmux.md` |
| Workstation package | combined contribution, package catalog, tests, docs |
| Neovim language | `languages/profile.lua`, lockfiles if needed, behavior case |
| Removed deployed source | `home/.chezmoiremove` unless inside an `exact` target |
| New platform condition | external template, capability support, feature backend, CI/test coverage |

## Do not

- Recreate the retired root Go CLI, root `go.mod`, root `internal/`, root `cmd/`, nested Go service modules, or any Makefile.
- Install managed tools with `sudo` or an OS package manager.
- Add unpinned downloads.
- Duplicate LazyVim language imports outside `languages/profile.lua`.
- Put feature workflows in `setup/platforms/`.
- Commit generated plugin, Mason, parser, cache, session, or history state.
- Add shell or PowerShell wrappers around `chezmoi apply` or `chezmoi update`.

<!-- BACKLOG.MD GUIDELINES START -->
<!-- backlog.md-instructions-version: 1.50.1 -->
<CRITICAL_INSTRUCTION>

## Backlog.md Workflow

This project uses Backlog.md for task and project management.

**For every user request in this project, run `backlog instructions overview` before answering or taking action.**

Use the overview to decide whether to search, read, create, or update Backlog tasks.

Before task lifecycle actions, read the matching detailed guide:
- `backlog instructions task-creation` before creating or splitting tasks
- `backlog instructions task-execution` before planning, changing status or assignee, adding a plan or implementation notes, or implementing task work
- `backlog instructions task-finalization` before checking acceptance criteria, writing final summaries, or moving tasks to terminal statuses

Use `backlog <command> --help` before running unfamiliar commands. Help shows options, fields, and examples.

Do not edit Backlog task, draft, document, decision, or milestone markdown files directly. Use the `backlog` CLI so metadata, relationships, and history stay consistent.

</CRITICAL_INSTRUCTION>
<!-- BACKLOG.MD GUIDELINES END -->
