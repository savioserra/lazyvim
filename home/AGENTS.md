# Chezmoi source-state instructions

Scope: `home/**`.

## Rules

- Every non-ignored file under this directory represents deployed state.
- `AGENTS.md` files are repository instructions and are excluded by `.chezmoiignore`.
- Use chezmoi source names: `dot_`, `private_`, `executable_`, `symlink_`, and `.tmpl`.
- Use real directories for nested target paths.
- Add removed non-`exact` targets to `.chezmoiremove`.
- Keep platform selection in templates or capability `supported_hosts`; do not create platform no-op feature declarations.
- Keep downloads checksum-pinned and user-local.
- Supported targets are Linux, WSL-as-Linux, and macOS. Retained native-Windows source is removal inventory, not a support promise.
- `dot_config/private_workstation/private_subagents/` owns only credential-free, vendor-neutral service configuration; its private source attributes must render 0700 directories and a 0600 file.
- Update version, URL, checksum, verification, and `docs/tools.md` together.

## Ownership

| Path | Owner |
| --- | --- |
| `.chezmoiexternals/` | Download inventory |
| `.chezmoiscripts/` | Public post-apply lifecycle entry points |
| `dot_local/share/workstation/` | Package-based workstation lifecycle application |
| `dot_pi/private_agent/skills/` | Global Pi skills |
| `dot_pi/private_agent/extensions/` | Source-managed Pi extensions; executable ownership, reload cleanup, discovery |
| `dot_config/nvim/` | Managed Neovim application configuration |
| `dot_config/tmux/`, `dot_tmux.conf` | Managed tmux configuration |
| `.chezmoiignore` | Target/platform exclusions |
| `.chezmoiremove` | Explicit stale-target removal |

Chezmoi scripts locate pinned Neovim and invoke the workstation CLI's `run.lua setup`
followed by `run.lua sync`. Keep lifecycle implementation in the deployed workstation
packages; do not add external apply/sync wrappers.
