# Go CLI migration analysis

## Previous state

The repository had approximately 2,200 lines of lifecycle logic split between 13 Bash entry points/libraries and 10 PowerShell entry points/libraries. The two implementations maintained the same invariants independently:

- parse `manifests/tools.env` and select an OS/architecture asset matrix;
- cache downloads, verify SHA-256, extract several archive layouts, and record release identity;
- back up unmanaged paths and create Unix links or Windows junctions/shims;
- bootstrap pinned chezmoi and apply the source state;
- restore Lazy, Mason, Tree-sitter, and tmux locks;
- validate versions, chezmoi drift, Mason receipts, plugin commits, tmux options, and headless startup;
- reject unsafe update/sync operations when Git or chezmoi state was dirty.

This worked, but fixes had to be reproduced in Bash and PowerShell. Installation also depended on curl, tar, unzip, a SHA utility, jq, and PowerShell-specific archive/hash APIs. Platform entry points encoded archive layouts separately, and shell syntax checks provided little unit-test coverage for download and extraction behavior.

## Migration result

All lifecycle behavior now enters through `cmd/lazyvim` and Cobra:

| Old entry point | Go command |
| --- | --- |
| `scripts/install*` | `lazyvim install` |
| `scripts/apply*` | `lazyvim apply` |
| `scripts/capture*` | `lazyvim capture` |
| `scripts/restore*` | `lazyvim restore` |
| `scripts/restore-tmux` | `lazyvim restore-tmux` |
| `scripts/check*` | `lazyvim check` |
| `scripts/update*` | `lazyvim update` |
| `scripts/sync*` | `lazyvim sync` |
| `scripts/lock-mason*` | `lazyvim lock-mason` |
| shell Neovim launcher | the Go executable invoked as `nvim` |

`internal/config` turns the shared manifest into typed platform catalogs. `internal/download` owns retries, partial files, cache reuse, embedded bundle lookup, and SHA-256. `internal/archive` handles zip, tar.gz, and tar.xz without host extraction commands and rejects traversal or unsafe special entries. `internal/app` owns cross-platform orchestration and keeps OS-specific policy at narrow filesystem/process boundaries.

## Embedding and bootstrap

`assets.go` embeds:

- `.chezmoiroot` and `home/`, allowing a prebuilt binary to install without a source checkout;
- both manifests, keeping release and tmux locks in the executable;
- `bundles/`, allowing selected or complete pinned archives to be compiled into an offline host-tool installer.

The downloader treats embedded files exactly like network files: it writes them through the same SHA-256 verifier before extraction. Missing bundles normally fall back to HTTPS; `install --offline --no-restore` instead fails closed on any missing host-tool archive. Plugin, Mason, parser, and tmux restoration is outside the host-archive bundle and remains disabled in offline mode. `lazyvim downloads bundle` populates build inputs, while `downloads list/fetch/verify/clean` manages the normal cache.

Source-mutating commands (`capture`, `update`, `sync`, and `lock-mason`) require a real checkout. Install records that checkout under lazyvim state so the managed CLI can find it from any working directory. A standalone binary materializes immutable embedded source under a content-addressed state directory for apply/restore/check.

## Preserved safety properties

- Existing unmanaged files are moved to timestamped backups.
- Downloads use partial files, retries, exact SHA-256 checks, and atomic publication.
- Release markers include platform and archive hash.
- Pre-marker Unix tools are adopted only when their executable format and architecture match.
- Archive paths cannot escape the staging root; symbolic links, hard links, device entries, oversized files, and excessive member counts are rejected.
- Installs stage releases before a rename into the versioned target.
- Lazy's committed lockfile is restored in a deferred cleanup path even when Neovim fails.
- tmux repositories must be clean Git checkouts and are forced to exact 40-character commits.
- update and sync still require clean Git and chezmoi states.

## Behavioral changes

- The host no longer needs curl, jq, tar, unzip, xz, or a SHA command for repository lifecycle operations.
- A compiled CLI is now the bootstrap artifact. `make` builds `.build/lazyvim`; Windows uses `go build` directly.
- Installer names are no longer platform-specific because runtime platform selection is typed and tested.
- Windows, Linux, and macOS share one archive/downloader implementation.
- Optional archive bundling can trade binary size for network independence.
- Shell and PowerShell parser checks were replaced by Go tests, vet, formatting checks, supported-target cross-compilation, and native-host integration jobs.

## Validation strategy

Unit tests cover manifest/platform completeness, archive prefix handling and traversal rejection, retry/checksum behavior, embedded downloads, Mason receipt parsing, Bash version parsing, and Cobra command exposure. CI then:

1. runs `gofmt`, race-enabled tests, and `go vet`;
2. cross-compiles all five supported targets;
3. performs native Linux, Apple Silicon macOS, Intel macOS, and Windows installation;
4. restores plugins, Mason packages, parsers, and tmux locks before the full runtime check;
5. rejects any tracked or untracked repository changes.
