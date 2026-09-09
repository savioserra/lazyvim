# Workstation runtime rationale

The current [package/lifecycle contract](capabilities.md) and
[backend/cutover procedure](chezmoi.md) own implementation and operating guidance.
This page records rationale, not another installation workflow.

## Decision and constraints

Pinned Neovim is the operational Lua host, not the composition boundary. Core
validates, materializes, orders and dispatches without importing packages or
Neovim. A standalone lifecycle Lua runtime would require a separate approved
decision, trustworthy pinned cross-platform binaries, adapter work and bootstrap
verification. It is not implemented or a prerequisite here.

## Historical context (not current instructions)

The initial Lua migration used `dot_local/share/lazyvim/lua/setup/` with separate
capability/feature catalogs, then a deployed engine under
`~/.local/share/workstation`. Chezmoi externals installed Neovim and run-after
scripts invoked setup/sync; `home/` and `.chezmoiroot` belonged to that layout.
TASK-34 inverts this ownership: the repo-native engine owns downloads and invokes
the file backend. Backlog notes and Git preserve authorization, failed attempts
and superseded plans; they are not current how-to instructions.

Old tmux observer/service experiments do not establish a standalone runtime or
extension contract. Pi resources follow [their current contract](capabilities.md#pi-resources);
user sessions/authentication stay outside the lifecycle.

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
