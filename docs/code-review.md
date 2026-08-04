# Installer code review

Reviewed after adding macOS and Windows support.

## Refactored architecture

- `scripts/install` is only an OS dispatcher.
- `scripts/install-linux` owns Linux architecture and release selection.
- `scripts/install-macos` owns macOS architecture and release selection.
- `scripts/lib/install-unix.sh` owns shared Bash option parsing, verified downloads, extraction, backups, linking, fonts, and restore orchestration.
- `scripts/install-windows.ps1` owns native Windows/PowerShell installation.
- `scripts/lib/Common.ps1` owns shared PowerShell paths, downloads, hashing, backups, links, shims, release markers, and native-command error handling.
- `scripts/install.ps1` remains a backward-compatible Windows wrapper.

The split keeps platform policy at the edge without duplicating the installation lifecycle.

## Findings addressed

### Combined Linux/macOS policy and mechanics

The original Bash installer mixed OS detection, every platform asset mapping, archive handling, fonts, linking, and restore behavior in one file. That made each new platform change risky and made platform-specific testing unclear.

**Resolution:** explicit platform entry points now populate a small configuration contract consumed by the shared Unix engine.

### Temporary directories leaked after failed extraction

`set -e` could terminate the old installer before `rm -rf` ran.

**Resolution:** temporary directories are registered immediately and removed by signal/exit traps as well as after successful installation.

### Version-named directories did not identify OS or architecture

An executable at `nvim-0.12.4` was accepted without knowing whether it came from Linux, Intel macOS, Apple Silicon, Windows x64, or Windows ARM64. This matters after architecture migrations or shared-home restores.

**Resolution:** every managed release directory now contains `.dotfiles-release` with its platform and archive SHA-256. A mismatched marker causes a safe backup and reinstall. Unix pre-marker installations are adopted only after checking the executable format and architecture; Windows pre-marker installations are safely reinstalled once because there is no dependency-free PE architecture check.

### Shell validation used a hand-maintained file list

Adding PowerShell files previously caused Bash to attempt parsing them, while newly added Bash entry points could be forgotten.

**Resolution:** validation now discovers shell libraries and executable scripts by type/mode, excluding non-executable PowerShell files.

### CI only exercised the minimal Neovim download

Companion asset URLs, archive layouts, and executable paths could regress without CI noticing.

**Resolution:** Linux, Apple Silicon macOS, Intel macOS, and Windows CI jobs now install all pinned companion tools (fonts remain skipped), then verify their versions.

### CI did not detect generated untracked files

`git diff --exit-code` only checked tracked changes.

**Resolution:** CI also requires `git status --porcelain` to be empty.

### PowerShell logging shadowed a built-in command

Compatibility aliases named `Write-Log` made command resolution less explicit.

**Resolution:** all code now calls `Write-DotfilesLog` and `Write-DotfilesWarning` directly.

## Remaining constraints

- Linux is currently x86_64-only because the complete pinned companion asset matrix has not been added for Linux ARM64.
- Standard GitHub-hosted Windows CI is x64. Windows ARM64 archives are checksum/layout validated, but the complete Mason toolchain still depends on each upstream package supporting ARM64.
- Mason locking relies on its receipt schema and official versioned install command because Mason does not provide a core lockfile. Changes to receipt schema should be caught by `lock-mason`/CI tests.
- Host tool updates are intentionally manual: version, URL, and digest must change together in `manifests/tools.env`.
- GitHub Actions are pinned to the maintained `actions/checkout@v4` major tag rather than an immutable commit SHA. Pinning the action SHA would further reduce CI supply-chain drift.
- Font installation touches platform font directories and registries. It is deliberately optional (`--no-font` / `-NoFont`) and backs up overwritten files where practical.

## Validation performed

- Bash 3.2 syntax (macOS-compatible)
- ShellCheck
- PowerShell parser and PSScriptAnalyzer
- actionlint
- Lua formatting and headless Neovim startup
- plugin and Mason lock validation
- release SHA-256 and archive-layout checks
- fresh Linux installation
- simulated Apple Silicon macOS extraction/install lifecycle
- GitHub Actions across Linux, Apple Silicon macOS, Intel macOS, and Windows
