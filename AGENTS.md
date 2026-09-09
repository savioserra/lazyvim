# Repository instructions

## Goal

Maintain a reproducible engine-owned workstation source state for Neovim and tmux on Linux,
WSL-as-Linux, and macOS (arm64).

## Read first

Read the nearest scoped `AGENTS.md` and follow the owning reference:

| Area | Reference |
| --- | --- |
| Navigation / install and daily use | [docs/index.md](docs/index.md) / [README.md](README.md) |
| Lifecycle and package contracts | [docs/capabilities.md](docs/capabilities.md) |
| File backend and guarded cutover | [docs/chezmoi.md](docs/chezmoi.md) |
| Checks and acceptance limits | [docs/testing.md](docs/testing.md) |
| Editor / terminal | [docs/nvim.md](docs/nvim.md) / [docs/tmux.md](docs/tmux.md) |
| Secret handling / pin inventory | [docs/secrets.md](docs/secrets.md) / [docs/tools.md](docs/tools.md) |

## Operating contract

- Edit source, not deployed state. The whole Git clone contains sibling `workstation/` and `chezmoi/`; never implicitly overwrite a clone or delete a legacy payload.
- `workstation/bin/workstation` is the sole public lifecycle interface. Chezmoi is the explicit-source/destination file backend; no public chezmoi aliases, source-path discovery, externals, lifecycle scripts or root wrappers.
- Register each lifecycle capability once under `workstation/packages/` in the explicit catalog. Keep core domain-neutral: no catalog/package/Neovim imports. Detailed composition and lifecycle rules belong to `docs/capabilities.md`.
- Bootstrap owns pinned Neovim/backend and launcher; setup owns other downloads. No Node bootstrap dependency, unpinned downloads, `sudo` or OS-package-manager installation of managed tools.
- Keep language composition in the Neovim profile. Do not recreate the retired root Go CLI (`go.mod`, `internal/`, `cmd/`), nested Go service modules, daemons, actor runtimes or any Makefile; Go is an editor toolchain here.
- Never commit generated plugin/Mason/parser/cache/session/history state or secret values. Secret-reference/vault work requires explicit user `/skill:secrets` invocation; authentication stays user-owned.

## Required checks

Run checks relevant to the change. Before completion, run all available fast checks:

```bash
sh .github/scripts/check.sh
```

Never run fixtures directly against an applied home: they write fake Node/npm state.
Follow [testing](docs/testing.md) for isolation, individual shell checks and retained
receipts. Audit full source before a backend render; dry-run is not a sandbox.
Real lifecycle/downloads require explicit authorization; synthetic checks do not
replace Linux/WSL and native macOS arm64 acceptance.

## Change rules

| Change | Required updates |
| --- | --- |
| Host tool version | `workstation/versions.json`, owning package URL/checksum, `docs/tools.md` |
| Node version | `chezmoi/dot_node-version`, canonical Node URL/checksum |
| Global npm capability | Exact version, registry integrity, feature setup/verify, docs |
| Pi extension package | Exact version or source-managed extension contract, setup/verify, Pi discovery, docs |
| Pi skill | `chezmoi/dot_pi/private_agent/skills/<name>/SKILL.md`, `pi-skills` verification, docs |
| tmux plugin pin | `workstation/packages/tmux/init.lua`, `docs/tmux.md` |
| Workstation package | combined contribution, package catalog, tests, docs |
| Neovim language | `languages/profile.lua`, lockfiles if needed, behavior case |
| Removed deployed source | `chezmoi/.chezmoiremove` unless inside an `exact` target |
| New platform condition | canonical asset metadata, capability support, package backend, CI/test coverage |

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
