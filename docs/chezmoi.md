# chezmoi mechanics

Source root: `home/` (set via `.chezmoiroot` at repo root). All paths below are relative to `home/` unless noted.

## Naming conventions in use

| Source prefix/pattern | Target |
| --- | --- |
| `dot_<name>` | `~/.<name>` |
| `dot_local/bin/symlink_<name>[.tmpl]` | `~/.local/bin/<name>`, a symlink; file content = symlink target |
| `.chezmoiscripts/run_<attrs>_<name>.<ext>[.tmpl]` | executed as a script; no corresponding file in `~`. `<attrs>` ∈ `{once,onchange}` × `{before,after}` |
| `.chezmoiexternal.toml[.tmpl]` | declares downloaded targets (not represented as source files at all) |
| `.chezmoiignore[.tmpl]` | excludes target paths, templated per `.chezmoi.os`/`.chezmoi.arch` |

Nested target paths require real nested source directories — `dot_local/bin/symlink_nvim.tmpl` produces `~/.local/bin/nvim`; a flat file named `symlink_dot_local_bin_nvim.tmpl` at the source root would instead produce `~/.local_bin_nvim` (verified).

Removing a source entry does not delete its deployed target — `chezmoi apply` only adds/updates what it still manages. Deleting a managed file from the repo also requires manually removing the deployed copy from `~`, unless it's inside an `exact` directory (e.g. the `.local/opt/nvim`/font externals, which prune on their own).

## `.chezmoiignore` matching for scripts

A script's `.chezmoiignore` target name has its `run_`/`once_`/`onchange_`/`before_`/`after_` attributes and `.tmpl` suffix already stripped — match against what's left, not the source filename.

Example: `.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl` → ignore pattern `.chezmoiscripts/30-tmux-plugins.sh`.

Current platform exclusions (`home/.chezmoiignore`):

| Excluded on | Paths |
| --- | --- |
| Windows | `.tmux.conf`, `.config/tmux/**`, `.local/bin/nvim`, `.chezmoiscripts/20-linux-fontcache.sh`, `.chezmoiscripts/30-tmux-plugins.sh` |
| Not Windows | `.chezmoiscripts/10-windows-path.ps1`, `.chezmoiscripts/20-windows-fonts.ps1` |
| Darwin | `.chezmoiscripts/20-linux-fontcache.sh` |

## `.chezmoiexternal.toml.tmpl`

Declares every pinned host-tool download. Full table in [tools.md](tools.md). Mechanics:

- `type = "archive-file"` — extracts one named file from an archive to a target path. Used for every flat single-binary tool.
- `type = "archive"` with `stripComponents = 1`, `exact = true` — extracts a whole tree (Neovim's runtime, fonts), dropping stale files across a version bump.
- Templated on `.chezmoi.os` / `.chezmoi.arch`; branches with no available upstream build for a platform (e.g. Windows ARM64 for `rainfrog`/`op`) render an empty URL, and the corresponding `[...]` table is skipped via `{{ if ne $url "" }}`.
- No `refreshPeriod` set anywhere — updates are explicit (edit version/URL/checksum, `chezmoi apply`), never automatic.

## `.chezmoiscripts/`

| Script (stripped name) | Phase | Platforms | Purpose |
| --- | --- | --- | --- |
| `30-tmux-plugins.sh` | after, onchange | Unix | `git clone`/`checkout` every tmux plugin (incl. TPM) to its exact pinned commit — TPM's own `#<ref>` install syntax only accepts branches/tags, not raw SHAs |
| `20-linux-fontcache.sh` | after, onchange | Linux only | `fc-cache -f` after font files land |
| `10-windows-path.ps1` | after, onchange | Windows only | Adds `.local\bin` and `.local\opt\nvim\bin` to user `PATH` |
| `20-windows-fonts.ps1` | after, onchange | Windows only | Registers each installed font under `HKCU:\...\CurrentVersion\Fonts` (per-user font install needs registry entries, not just files on disk) |

## Root-level layer

Two files live outside `home/` (read by `chezmoi init` before `.chezmoiroot` redirection): `.chezmoiroot` itself. No `.chezmoi.toml.tmpl` exists yet — add one at the repo root if machine-specific config data (e.g. 1Password integration settings) is needed.
