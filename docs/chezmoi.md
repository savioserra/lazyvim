# Chezmoi reference

Source root: `home/` via repository `.chezmoiroot`.

## Apply model

Chezmoi commands are the public workflow:

| Command | Source behavior | Lifecycle behavior |
| --- | --- | --- |
| `chezmoi init --apply <repo>` | Initialize and apply | Run setup, then sync |
| `chezmoi update` | Pull and apply | Run setup, then sync |
| `chezmoi apply` | Apply current source | Run setup, then sync |
| `chezmoi --source <checkout> apply` | Apply explicit checkout | Run setup, then sync |

Execution order:

```text
render source
  -> install/update externals
  -> apply managed files
  -> run_after_20-<host>-apply
       -> workstation/apps/cli/run.lua setup
       -> workstation/apps/cli/run.lua sync
```

`home/.chezmoiscripts/` owns lifecycle invocation. Do not add repository-level
apply or sync wrappers.

## Source naming

| Source | Target/behavior |
| --- | --- |
| `dot_<name>` | `~/.<name>` |
| `executable_<name>` | Executable target |
| `symlink_<name>[.tmpl]` | Symlink; contents are the target |
| `.chezmoiscripts/run_<attrs>_<name>[.tmpl]` | Executed action; no target file |
| `.chezmoiexternals/*.toml.tmpl` | Downloaded target declaration |
| `.chezmoiignore` | Excluded rendered target paths |
| `.chezmoiremove` | Targets removed during apply |

Use actual nested source directories. Example:

```text
dot_local/bin/symlink_nvim.tmpl -> ~/.local/bin/nvim
```

## Platform selectors

| Template value | Values used |
| --- | --- |
| `.chezmoi.os` | `linux`, `darwin`, `windows` |
| `.chezmoi.arch` | `amd64`, `arm64` |
| `.chezmoi.destDir` | Target home |

WSL uses the Linux branch.

## Ignore rules

Agent instruction files are repository-only:

```text
AGENTS.md
**/AGENTS.md
```

Script ignore names use stripped target names. Remove `run_`, lifecycle
attributes, and `.tmpl` before matching.

```text
source: .chezmoiscripts/run_after_20-unix-apply.sh.tmpl
ignore: .chezmoiscripts/20-unix-apply.sh
```

| Host | Excluded targets |
| --- | --- |
| Windows | tmux config, Unix shell config, Unix symlinks, tmux-subagents launcher/extension/skill/application, Unix apply script |
| Linux/macOS | Windows apply script |

## External types

| Type | Use | Required fields |
| --- | --- | --- |
| `archive-file` | One binary from an archive | `url`, `path`, checksum, `executable` |
| `archive` | Complete application/tool tree | `url`, checksum, usually `stripComponents` |

Rules:

- Set `exact = true` for complete owned trees that must prune stale files.
- Omit unavailable platform tables; do not render empty URLs.
- Do not set `refreshPeriod`; updates are explicit.
- Keep version, URL, checksum, and verification changes atomic.
- Install into user-local targets only.
- Do not add an external for a locally built TUI bundle until immutable release URLs and final archive checksums exist; build-workflow artifacts alone are not a deployment source.

Inventory: [`tools.md`](tools.md).

## Post-apply scripts

| Stripped name | Hosts | Ordered commands |
| --- | --- | --- |
| `20-unix-apply.sh` | Linux/macOS | Workstation CLI `setup`; then `sync` |
| `20-windows-apply.cmd` | Windows | Workstation CLI `setup`; then `sync` |

Script requirements:

- use the pinned Neovim under the target home;
- use the deployed `.local/share/workstation/apps/cli/run.lua` under the target home;
- stop before sync when setup fails;
- return the sync exit code;
- avoid shell-specific orchestration outside path resolution and failure handling.

## Removal rules

| Target kind | Removal mechanism |
| --- | --- |
| File/non-exact directory | Add target path to `home/.chezmoiremove` |
| `exact = true` external tree | External apply prunes stale children |
| Platform-obsolete target | Add `.chezmoiremove`; retain appropriate ignore condition |

## Render checks

```bash
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

Use `.github/scripts/test-apply.ps1` for an applied scratch-home test. The test
calls chezmoi directly; post-apply scripts execute setup and sync.
