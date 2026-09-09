# Workstation runtime rationale

| Property | Current contract |
| --- | --- |
| Public entry point | `workstation/bin/workstation`, installed as a home symlink by bootstrap |
| Lua host | Engine-installed checksum-pinned Neovim; no user config in the parent |
| File backend | Engine-installed pinned chezmoi with explicit source/destination |
| Composition | Explicit package catalog; domain-neutral core; Neovim is one package |
| Bootstrap dependency | POSIX shell and download/archive/hash essentials, not Node or system Lua |
| Source layout | Whole Git clone containing sibling `workstation/` and `chezmoi/` |

## Decision and constraints

Pinned Neovim is an operational Lua-host dependency, not the composition boundary.
Factories contribute metadata and optional lifecycle handlers through one record;
core validates, materializes, orders and dispatches without importing packages or
Neovim. A standalone lifecycle Lua runtime would need a separate approved decision,
trustworthy pinned cross-platform binaries, adapter work and bootstrap verification.
It is not implemented or a prerequisite here.

Bootstrap installs runtime, backend and the public launcher. Apply performs guarded
legacy retirement, files, Node pin/PATH refresh and setup. Sync restores mutable
application state separately. Update checks pull, freshly launched bootstrap,
apply, sync and verify in order. See `capabilities.md` and `chezmoi.md` for contracts.

## Historical context (not current instructions)

The initial Lua migration used `dot_local/share/lazyvim/lua/setup/` with separate
capability/feature catalogs, then a deployed workstation engine under
`~/.local/share/workstation`. Chezmoi externals installed Neovim and run-after
scripts invoked setup/sync. The former `home/` source layout and `.chezmoiroot`
marker belonged to that architecture. TASK-34 inverts this ownership: the engine
is repo-native, owns downloads and invokes the file backend. Backlog/research
records preserve those historical decisions; they are not installation guidance.

The old tmux observer and service experiments do not define a current standalone
runtime or extension contract. Current Pi resources are documented in
`capabilities.md`; user sessions/authentication stay outside the lifecycle.

## Rejected implicit dependencies

| Option | Reason |
| --- | --- |
| Managed Node as bootstrap host | Circular: Node provisioning would require Node |
| System Lua/Neovim | Not reliably installed or pinned on fresh hosts |
| Per-platform lifecycle implementations | Duplicate domain behavior |
| Filesystem package discovery | Hides ordering and weakens reproducibility |
| Deployed/generated engine mirror | Competing source ownership and unsafe clone cleanup |

References: [Neovim -l](https://neovim.io/doc/user/starting/),
[Neovim Lua](https://neovim.io/doc/user/lua/).
