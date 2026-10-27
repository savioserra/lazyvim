# Repository instructions

## Goal

Maintain a reproducible workstation source state: a nixpkgs-native
substrate for Linux (WSL counts as linux) and macOS (arm64) — capability
modules declared once, rendered by home-manager, switched by one command.

## Read first

Read the nearest scoped `AGENTS.md` and follow the owning reference:

| Area | Reference |
| --- | --- |
| Navigation / install and daily use | [docs/index.md](docs/index.md) / [README.md](README.md) |
| Lifecycle and capability contracts | [docs/capabilities.md](docs/capabilities.md) |
| Home state law | [docs/home-state.md](docs/home-state.md) |
| Checks and acceptance limits | [docs/testing.md](docs/testing.md) |
| Editor / terminal | [docs/nvim.md](docs/nvim.md) / [docs/tmux.md](docs/tmux.md) |
| Secret handling / tool inventory | [docs/secrets.md](docs/secrets.md) / [docs/tools.md](docs/tools.md) |

## Operating contract

- A capability that names a tool ships the tool: resources-without-runtime (a clone, a symlink or a config with no provisioned, working binary) is a defect, not a documented manual step. Verify must smoke the consumer (`hermes --version`-class checks), not only fingerprints.
- Edit source, not deployed state. Every payload lives with its owning capability under `modules/<domain>/` (module and bytes co-located); home state is declared and linked from the store, never checked in as deployed state. Never implicitly overwrite a clone; legacy payloads retire through the declared retire list.
- `bin/workstation` is the sole public lifecycle interface; `workstation-switch` (staged into each generation) is the sole write plane.
- Keep core domain-neutral: no cross-domain imports; composition happens through the capability walk (`nix/lib/capabilities.nix`).
- Payload stays data: Lua appears only as deployed editor/theme data read as bytes, never executed.
- Tools come from nixpkgs through the flake's pin-override overlay (`overlays.default`) with version floors asserted in the owning modules, or an inline pin where nixpkgs lacks coverage (documented in the owning module). No unpinned downloads, no `sudo`, no OS-package-manager installation of managed tools.
- Keep language composition in the Neovim profile. Go is an editor toolchain here (no root Go CLI, no services, no Makefiles).
- Never commit generated plugin/Mason/parser/cache/session/history state or secret values. Secret-reference/vault work requires explicit user `/skill:secrets` invocation; authentication stays user-owned.
- The identity gate reds on personal strings anywhere in the tracked tree; `hosts/identity.nix` (the machine's captured identity) stays uncommitted.
- Work lands roadmap-style: future work is seeded as a parent-chained chain (task1 → task2 → …), serial within a surface. A card whose declared surface overlaps an in-flight card's waits behind it via a parent link — never dispatched alongside it.
- Phase labels (P0, P1, …) are transient planning scaffolding: they live in card bodies and board surfaces, never in landed repo content — no phase-named code, comments, docs, config keys or commit messages survive to the merged tree.
- A card is done only when its declared surface exists at git HEAD: workers deliver branch commits (or land them), and `kanban_complete` metadata names the commit sha. Uncommitted scratch work is not a done state — feature-sized cards run in persistent workspaces (`worktree:`/`dir:`), never scratch; if work must ride uncommitted, the card names it orchestrator-owned and stays open until landed. The reviewer/lead verifies the surface at HEAD before accepting.

## Required checks

Run checks relevant to the change. Before completion, run all available fast checks:

```bash
sh .github/scripts/check.sh
```

Never run fixtures directly against an applied home. Behavioral acceptance
owns isolation: the container E2E for the home plane, the eval gates for the
declared surface. Native Linux and macOS arm64 acceptance stays explicit.

## Change rules

| Change | Required updates |
| --- | --- |
| Tool version | the tool's floor in its owning capability's module, `docs/tools.md` |
| Neovim version | the editor domain's neovim floor (`modules/editor/editor.nix`), `docs/tools.md` |
| Hermes Agent pin | the flake's `hermes-agent` input rev, `modules/agent/agent.nix`, `docs/tools.md` |
| Managed Hermes skill | `modules/agent/skills/<name>/`, the `programs.hermes.skills` entry, `modules/agent/verify/hermes.sh`, `docs/capabilities.md` |
| tmux plugin pin | the `fetchFromGitHub` rev in `modules/terminal/terminal.nix`, `docs/tmux.md` |
| Capability | `modules/<domain>/` (module + payload bytes co-located), tests, docs |
| Neovim language | the language entry in the language domain's module, lockfiles if needed, behavior case |
| Removed deployed source | a retire-list entry in the owning capability's module (the generation diff retires file-plane-owned targets; the activation retire list retires legacy paths) |
| New platform condition | canonical asset metadata, capability support, CI/test coverage |
