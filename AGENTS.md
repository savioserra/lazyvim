# Repository instructions

## Goal

Maintain a reproducible engine-owned workstation source state for Neovim and tmux on Linux,
WSL-as-Linux, and macOS (arm64).

## Read first

| Area | Reference |
| --- | --- |
| Repository map | `docs/index.md` |
| Subordinate file backend/cutover | `docs/chezmoi.md` |
| Capability boundaries | `docs/capabilities.md` |
| Neovim | `docs/nvim.md` |
| tmux | `docs/tmux.md` |
| Secrets | `docs/secrets.md` |
| Managed tools | `docs/tools.md` |

Use the nearest `AGENTS.md` for scoped rules.

## Architecture rules

- Define each lifecycle capability once under `workstation/packages/`.
- Keep `workstation/lua/workstation/core/` domain-neutral. It must not import the catalog, packages, or Neovim.
- Register each package once in the explicit ordered `workstation/lua/workstation/catalog.lua`; do not auto-discover packages.
- Keep complex behavior and feature-specific OS branches inside the owning package.
- Let the core materializer explicitly split graph specifications from lifecycle handlers; do not deep-merge contributions.
- Keep Neovim language composition in `lua/languages/profile.lua`, not in lifecycle capabilities.
- Keep `workstation/bin/workstation` the sole public lifecycle interface; chezmoi is the subordinate file backend with explicit source/destination.
- Bootstrap owns pinned Neovim/backend and the public launcher; setup owns other downloads and post-materialization host configuration. Do not add root wrappers, externals or lifecycle scripts.
- Apply performs guarded real-account legacy retirement, files, Node pin/PATH refresh and setup; sync separately restores mutable application state. Update checks pull, fresh bootstrap, apply, sync and verify in order.
- The source clone is the whole repository with sibling `workstation/` and `chezmoi/`; never delete an old payload or overwrite a clone implicitly. See guarded cutover instructions.
- Do not add Node as a bootstrap dependency; pinned Neovim is the lifecycle runtime until the standalone workstation runtime replaces it.
- Do not add Go service modules, daemons, or actor runtimes to this repository; the Go toolchain exists only for the Neovim language profile.

## Required checks

Run checks relevant to the change. Before completion, run all available fast checks:

```bash
sh .github/scripts/check.sh
```

The runner freezes installed Neovim/Mason StyLua paths before giving every suite
and check a fresh private HOME, TMP, XDG and cache with cleared ambient state.
Do not run fixture suites directly against an applied home: they write fake
Node/npm state. Test-only `test-home.sh` retains its owned `/tmp/workstation-test.*`
roots (printed on stderr) for inspection; no caller path is recursively deleted.
It preserves only prerequisite PATH, not auth/agent/session/tool configuration.

Check every shell file separately with `sh -n` and available ShellCheck (see `.github/scripts/check.sh`). Inspect the full source before the isolated backend render in `docs/chezmoi.md`; dry-run alone is not a sandbox. Real `.github/scripts/test-apply.sh` bootstrap/apply/sync/checks/verify requires explicit network/installation authorization. Full supported-platform verification runs on Linux/WSL and macOS (arm64); synthetic tests are not deployment acceptance.

## Change rules

| Change | Required updates |
| --- | --- |
| Host tool version | `workstation/versions.json`, owning package URL/checksum, `docs/tools.md` |
| Node version | `chezmoi/dot_node-version`, canonical Node URL/checksum |
| Global npm capability | Exact version, registry integrity, feature setup/verify, docs |
| Pi extension package | Exact version or source-managed extension contract, setup/verify, Pi discovery, docs |
| Pi skill | `chezmoi/dot_pi/private_agent/skills/<name>/SKILL.md`, `pi-skills` verification, docs |
| tmux plugin pin | `packages/tmux/init.lua`, `docs/tmux.md` |
| Workstation package | combined contribution, package catalog, tests, docs |
| Neovim language | `languages/profile.lua`, lockfiles if needed, behavior case |
| Removed deployed source | `chezmoi/.chezmoiremove` unless inside an `exact` target |
| New platform condition | canonical asset metadata, capability support, package backend, CI/test coverage |

## Do not

- Recreate the retired root Go CLI, root `go.mod`, root `internal/`, root `cmd/`, nested Go service modules, or any Makefile.
- Install managed tools with `sudo` or an OS package manager.
- Add unpinned downloads.
- Duplicate LazyVim language imports outside `languages/profile.lua`.
- Put feature workflows in `setup/platforms/`.
- Commit generated plugin, Mason, parser, cache, session, or history state.
- Restore public chezmoi lifecycle aliases, source-path discovery or lifecycle run-after scripts.

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
