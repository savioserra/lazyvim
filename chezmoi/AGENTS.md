# Chezmoi source-state instructions

Scope: `chezmoi/**`.

## Rules

- Every non-ignored file under this directory represents deployed state.
- `AGENTS.md` files are repository instructions and are excluded by `.chezmoiignore`.
- Use chezmoi source names: `dot_`, `private_`, `executable_`, `symlink_`, and `.tmpl`.
- Use real directories for nested target paths.
- Add removed non-`exact` targets to `.chezmoiremove`.
- Keep platform selection in templates or capability `supported_hosts`; do not create platform no-op feature declarations.
- Keep downloads in engine bootstrap/package setup, checksum-pinned and user-local; this source owns files only.
- Supported targets are Linux, WSL-as-Linux, and macOS (arm64).
- Update version, URL, checksum, verification, and `docs/tools.md` together.

## Ownership

| Path | Owner |
| --- | --- |
| `dot_pi/private_agent/skills/` | Global Pi skills |
| `dot_pi/private_agent/extensions/` | Source-managed Pi extensions; executable ownership, reload cleanup, discovery |
| `dot_config/nvim/` | Managed Neovim application configuration |
| `dot_config/tmux/`, `dot_tmux.conf` | Managed tmux configuration |
| `.chezmoiignore` | Target/platform exclusions |
| `.chezmoiremove` | Explicit stale-target removal |

The repo-native engine invokes chezmoi with explicit source and destination, then
refreshes the materialized Node pin/PATH and runs setup. Sync is separate. Never
add lifecycle run-after scripts, archive externals, a deployed engine copy or a
chezmoi-managed public launcher. The whole Git clone hosts `workstation/` beside
this directory; source discovery does not depend on a `.chezmoiroot` marker.
