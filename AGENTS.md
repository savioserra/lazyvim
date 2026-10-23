# Repository instructions

## Goal

Maintain a reproducible engine-owned workstation source state. The engine is
Elixir-only (the OTP release is the engine; Neovim is a managed host
capability, never an engine dependency) for Linux, WSL-as-Linux, and macOS
(arm64).

## Read first

Read the nearest scoped `AGENTS.md` and follow the owning reference:

| Area | Reference |
| --- | --- |
| Navigation / install and daily use | [docs/index.md](docs/index.md) / [README.md](README.md) |
| Lifecycle and capability contracts | [docs/capabilities.md](docs/capabilities.md) |
| Home state law and legacy cutover | [docs/chezmoi.md](docs/chezmoi.md) |
| The absorption: manifests → native declarations | [docs/absorption.md](docs/absorption.md) |
| Checks and acceptance limits | [docs/testing.md](docs/testing.md) |
| Editor / terminal | [docs/nvim.md](docs/nvim.md) / [docs/tmux.md](docs/tmux.md) |
| Secret handling / pin inventory | [docs/secrets.md](docs/secrets.md) / [docs/tools.md](docs/tools.md) |

## Operating contract

- A capability that names a tool ships the tool: resources-without-runtime (a clone, a symlink or a config with no provisioned, working binary) is a defect, not a documented manual step. Verify must smoke the consumer (`hermes --version`-class checks), not only fingerprints. Operator ruling 2026-10-15.

- Edit source, not deployed state. Every home-state payload lives with its owning capability under `workstation/packages/` (renamed `workstation/payload/` by the absorption chain); home state is declared in `nix/modules/capabilities/` and linked from the store, never checked in as deployed state. Never implicitly overwrite a clone or delete a legacy payload.
- `workstation/bin/workstation` is the sole public lifecycle interface and `workstation-switch` is the sole write plane. There is no chezmoi: no aliases, source-path discovery, externals, lifecycle scripts or root wrappers.
- Declare each lifecycle capability once as a native nix module under `nix/modules/capabilities/`; payload stays with the owning capability under `workstation/packages/` (→ `workstation/payload/`). Keep core domain-neutral: no catalog/package/Neovim imports. Detailed composition and lifecycle rules belong to `docs/elixir.md`.
- The engine path is Elixir-only: no Lua execution and no nvim invocation anywhere in the engine (`workstation/packages/**/*.lua` are data/payload files read as bytes, never run). `workstation/bin/workstation` stays plain POSIX sh: sandbox, runtime/release acquisition, then exec of the engine release.
- Interactive verbs render the TUI by default; non-interactive callers pass `--headless` explicitly — a non-TTY run without the flag hard-errors instead of degrading silently.
- All downloads are pinned declarations rendered by the substrate. No Node bootstrap dependency, unpinned downloads, `sudo` or OS-package-manager installation of managed tools.
- Keep language composition in the Neovim profile. Do not recreate the retired root Go CLI (`go.mod`, `internal/`, `cmd/`), nested Go service modules, daemons, actor runtimes or any Makefile; Go is an editor toolchain here.
- Never commit generated plugin/Mason/parser/cache/session/history state or secret values. Secret-reference/vault work requires explicit user `/skill:secrets` invocation; authentication stays user-owned.
- Work lands roadmap-style: future work is seeded as a parent-chained chain (task1 → task2 → …), serial within a surface. A card whose declared surface overlaps an in-flight card's waits behind it via a parent link — never dispatched alongside it. Operator ruling 2026-10-15.
- A card is done only when its declared surface exists at git HEAD: workers deliver branch commits (or land them), and `kanban_complete` metadata names the commit sha. Uncommitted scratch work is not a done state — feature-sized cards run in persistent workspaces (`worktree:`/`dir:`), never scratch; if work must ride uncommitted, the card names it orchestrator-owned and stays open until landed. The reviewer/lead verifies the surface at HEAD before accepting. Operator ruling 2026-10-20 (the t_f595e580 phantom landing).

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
| Host tool version | `workstation/versions.json`, the owning capability's pin row, `docs/tools.md` |
| Node version | `workstation/packages/languages/node/files/.node-version`, canonical Node URL/checksum |
| Global npm capability | Exact version, registry integrity, feature setup/verify, docs |
| Hermes Agent pin | `workstation/versions.json` (`hermes_agent_git_commit`), the hermes module row (`nix/modules/hermes.nix`), `docs/tools.md` |
| Managed Hermes skill | `workstation/packages/agent/files/.hermes/skills/<name>/SKILL.md`, the `workstation.hermes.skills` entry in `nix/modules/hermes.nix`, `workstation/packages/agent/verify/hermes.sh`, `docs/capabilities.md` |
| tmux plugin pin | `workstation/packages/terminal/tmux/init.lua` (payload data; the checkouts themselves provision via the capability layer, not engine recipes), `docs/tmux.md` |
| Workstation capability | native nix module (`nix/modules/capabilities/<name>.nix`), payload assets, tests, docs |
| Neovim language | the language entry in `nix/modules/capabilities/nvim.nix`, lockfiles if needed, behavior case |
| Removed deployed source | a retire-list entry in the owning capability's module (the generation diff retires file-plane-owned targets; the activation retire list retires legacy paths) |
| New platform condition | canonical asset metadata, capability support, package backend, CI/test coverage |

