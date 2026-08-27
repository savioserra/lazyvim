# ADR: workstation lifecycle runtime and package boundary

| Field | Value |
| --- | --- |
| Status | Accepted; Phase 1 implemented |
| Application | Workstation package monorepo |
| Phase 1 runtime | Checksum-pinned Neovim used only as the Lua launcher |
| Entry point | `nvim -l ~/.local/share/workstation/apps/cli/run.lua <setup|sync|verify>` |
| User config loaded by parent | No |
| Neovim integration | Ordinary `packages.nvim` contribution |
| Bootstrap dependency | Chezmoi-installed Neovim |
| Node role | Managed package; not a runtime dependency |

## Decision

The lifecycle system is separated from the Neovim package and deployed as a workstation application. Each package contributes capability metadata and optional lifecycle behavior through one combined record and is registered once in an explicit catalog. Domain-neutral core modules validate, materialize, order, and dispatch packages without importing them.

Phase 1 deliberately retains pinned Neovim as the cross-platform Lua host. This is an operational dependency, not the composition boundary. A standalone Lua runtime is a separate Phase 2 decision requiring trustworthy cross-platform binaries, checksums, bootstrap templates, and platform verification.

## Constraints

- The runtime must exist before post-apply scripts execute.
- Setup must work before Node environment configuration.
- One Lua implementation must run on all supported hosts.
- Chezmoi remains the archive/file provisioner and public apply interface.
- Editor behavior checks still require configured Neovim child processes.
- The core package must not import Neovim or lifecycle packages.

## Execution sequence

```text
chezmoi externals
  -> pinned Neovim launcher
  -> workstation CLI setup
  -> workstation CLI sync
  -> workstation CLI verify
```

## Phase 1 layout

```text
dot_local/share/workstation/
├── apps/cli/run.lua
├── versions.json
└── lua/workstation/
    ├── app.lua
    ├── catalog.lua
    ├── core/
    ├── packages/
    ├── host/
    └── platforms/
```

The workspace remains below the chezmoi source root so its files deploy directly. Top-level generated mirrors or repository wrappers are not used.

## Earlier architecture

The initial Lua migration used `dot_local/share/lazyvim/lua/setup/` with separate data-only capability and feature catalogs. That design proved reproducible but required every capability to be registered twice and made Neovim appear to own the wider workstation lifecycle. The package monorepo supersedes those composition boundaries while preserving lifecycle semantics and the Neovim-hosted bootstrap.

## Standalone tmux observer runtime

The tmux subagent interface no longer carries a standalone Lua runtime. It is a Linux/macOS-only source-managed XState extension with a separate Terminal Kit Node renderer installed from an exact local lock. Managed Node already belongs to the workstation package graph; renderer absence keeps only this optional capability disabled and does not affect lifecycle setup, sync, or managed subagent runs.

## Deferred Phase 2

A future ADR may select and pin a standalone Lua runtime for the lifecycle application, replace Neovim-specific platform primitives with an injected runtime adapter, and switch post-apply scripts. The Node renderer is not a lifecycle Lua replacement: lifecycle Phase 2 still requires all five host targets and bootstrap verification. Phase 2 must not introduce Node, Go, system Lua, or per-platform orchestration as an implicit bootstrap dependency.

## Rejected approaches

| Option | Reason |
| --- | --- |
| Managed Node | Circular bootstrap: Node setup would require Node |
| System Lua | Not consistently present or versioned across hosts |
| Per-platform lifecycle implementations | Duplicates lifecycle and verification behavior |
| Filesystem package discovery | Hides order and weakens reproducibility |
| Generated top-level package mirror | Adds a second source of truth outside chezmoi deployment |

## External references

- [Neovim `-l`](https://neovim.io/doc/user/starting/)
- [Neovim Lua modules](https://neovim.io/doc/user/lua/)
- [lazy.nvim spec structure](https://lazy.folke.io/usage/structuring)
