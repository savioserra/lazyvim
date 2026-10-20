# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS (arm64).

| Property | Value |
| --- | --- |
| Download operations | Owning `workstation/packages/<name>/` setup; the installer's mise-first acquisition (fresh box); Neovim bootstrap and engine-owned chezmoi backend |
| Shared versions, URL templates and SHA-256 | `workstation/versions.json` |
| Node version | `workstation/packages/languages/node/files/.node-version` |
| Update unit | Version, URL, SHA-256 checksum, verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| chezmoi backend | 2.72.1 | github.com/twpayne/chezmoi | `.local/opt/chezmoi/bin/chezmoi` (engine-owned) | linux-x86_64, darwin-arm64 |
| Neovim | 0.12.4 | github.com/neovim/neovim | `.local/opt/nvim` (exact tree, engine bootstrap) | linux-x86_64, darwin-arm64 |
| Go | 1.27.1 | go.dev | `.local/opt/go` (exact tree via the download contract's archive form) + `.local/bin/go` link | linux-x86_64, darwin-arm64 |
| Herdr | 0.9.0 | github.com/herdrdev/herdr | `.local/opt/herdr/bin/herdr` (`herdr` setup) + `.local/bin/herdr` link | linux-x86_64, darwin-arm64 (WSL uses the Linux asset) |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (exact tree via the download contract, content probe `nvm.sh`; `node` package) | linux-x86_64, darwin-arm64 |
| Node.js | `workstation/packages/languages/node/files/.node-version` (currently 24.19.0) | nodejs.org | `.local/opt/nvm/versions/node/v<version>` (exact tree via the download contract, probe `bin/node --version`; nested in the provisioned nvm tree, declared parent-first) | linux-x86_64, darwin-arm64 |
| pnpm | 12.14.0 | github.com/pnpm/pnpm | `.local/opt/pnpm` (download-contract archive, `flat` layout — the rootless `pnpm` + `dist/` standalone tree, probe `pnpm --version`; `typescript` package) + `.local/bin/pnpm` link | linux-x86_64, darwin-arm64 |
| ripgrep | 15.2.0 | github.com/BurntSushi/ripgrep | `.local/opt/ripgrep` (download-contract archive, probe `rg --version`) + `.local/bin/rg` link | linux-x86_64, darwin-arm64 |
| fd | 10.4.2 | github.com/sharkdp/fd | `.local/opt/fd` (download-contract archive, probe `fd --version`) + `.local/bin/fd` link | linux-x86_64, darwin-arm64 |
| eza | 0.23.5 | github.com/eza-community/eza | `.local/opt/eza` (download-contract archive — the lone root file IS the tree, content probe pins the binary bytes: the version token is not on the first `--version` line) + `.local/bin/eza` link; the managed `ls` alias rides the `prompt` package's guarded rc fragments | linux-x86_64 (no darwin asset upstream — brew/conda-only; absent-and-fine on darwin) |
| starship | 1.27.0 | github.com/starship/starship | `.local/opt/starship` (download-contract archive — the lone root file IS the tree, probe `starship --version` = `starship {V}`) + `.local/bin/starship` link; per-shell init + the omarchy-lean config at `.config/starship.toml` ride the `prompt` package's guarded rc fragments | linux-x86_64, darwin-arm64 |
| fzf | 0.74.2 | github.com/junegunn/fzf | `.local/opt/fzf` (download-contract archive — the lone root file IS the tree, probe `fzf --version`) + `.local/bin/fzf` link | linux-x86_64, darwin-arm64 |
| lazygit | 0.63.1 | github.com/jesseduffield/lazygit | `.local/opt/lazygit` (download-contract archive, `flat` rootless layout, exec probe carrying the pinned release metadata) + `.local/bin/lazygit` link | linux-x86_64, darwin-arm64 |
| tree-sitter (CLI) | 0.26.11 | github.com/tree-sitter/tree-sitter | `.local/opt/tree-sitter` (download-contract zip archive, probe `tree-sitter --version`) + `.local/bin/tree-sitter` link | linux-x86_64, darwin-arm64 |
| rainfrog | 0.4.4 | github.com/achristmascarl/rainfrog | `.local/opt/rainfrog` (download-contract archive, `flat` layout, exec probe carrying the pinned build id) + `.local/bin/rainfrog` link | linux-x86_64, darwin-arm64 |
| 1Password CLI | 2.39.0 | cache.agilebits.com | `.local/opt/op` (download-contract zip archive, `flat` layout — `op` + `op.sig`, probe `op --version`) + `.local/bin/op` link; verified by the `secrets` capability | linux-x86_64, darwin-arm64 |
| Hermes Agent | commit `b23600860f8` (git pin, `hermes_agent_git_commit`) + python-build-standalone `3.14.7` (archive pin, `hermes_python`; the release hermes-agent's `pm/lock.json` carries at the commit) | github.com/NousResearch/hermes-agent; github.com/astral-sh/python-build-standalone | Engine-provisioned full stack: pinned checkout `~/.hermes/hermes-agent` (git recipe), pinned interpreter `.local/opt/hermes/python` (download contract, probe `bin/python3 --version`), engine launcher `.local/opt/hermes/bin/hermes` surfaced as `.local/bin/hermes`; managed skills engine-owned; verified by `packages/agent/verify/hermes.sh` (consumer smoke `hermes --version` on every host) | linux-x86_64, darwin-arm64 |
| JetBrainsMono Nerd Font | 3.5.0 | github.com/ryanoasis/nerd-fonts | Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont` | linux-x86_64, darwin-arm64 |
| nunchux (launcher package; plugin active) | 3.1.3 | github.com/datamadsen/nunchux | pinned checkout `.tmux/plugins/nunchux` (git recipe at the v3.1.3 commit; carries the repo-tracked binary) + `bin/.platform` marker so upstream's `ensure_binary` never fetches ([tmux](tmux.md)) | linux-amd64 (repo build, content-pinned); package is linux-only, darwin release pin recorded as inventory |
| mise | 2026.10.8 | github.com/jdx/mise | Engine-owned: the raw release binary pinned at `.local/opt/mise/<version>/bin/mise` (download contract, `mise_bin_<plat>_url`/`_sha256`), surfaced on PATH as the contract-maintained symlink `.local/bin/mise`; activated in shells by the managed mise fragment. The installer's first-acquisition copy at `.local/bin/mise` is absorbed by content proof at apply | linux-x86_64, darwin-arm64 |
| tmux (binary) | 3.7c | `aqua:tmux/tmux-builds` via the engine mise contract | Contract-declared in the tmux package's managed tool set with the `linux` platform scope (`MISE_DATA_DIR` under the engine state root, composed `.config/mise/config.toml`); resolution probes go through mise itself (`mise where`); on darwin the scoped declaration is skipped and tmux stays a host prerequisite (brew) | linux-x86_64 |
| btop | 1.4.7 | `github:aristocratos/btop` via the engine mise contract | Same managed tool set and `linux` scope as the tmux binary (btop ships no darwin release assets); on darwin it stays a host prerequisite (brew) | linux-x86_64 |
| TPM plugin set (tpm, tmux2k, tmux-yank, tmux-resurrect, vim-tmux-navigator) | pinned commits ([tmux](tmux.md) Plugin pins) | github.com/tmux-plugins/tpm, github.com/2KAbhishek/tmux2k, github.com/tmux-plugins/tmux-yank, github.com/tmux-plugins/tmux-resurrect, github.com/christoomey/vim-tmux-navigator | engine-provisioned pinned checkouts `~/.tmux/plugins/<name>` (git recipes in the tmux package manifest; tpm leads — it must exist before the first tmux start); verified by `packages/tmux/verify/tmux.sh` | linux-x86_64, darwin-arm64 |

## Provisioning ownership

| Owner | Setup assets | Layout policy |
| --- | --- | --- |
| `foundation` | rg, fd, fzf, lazygit, tree-sitter, rainfrog | Download-contract archive form per tool: SHA-256-gated release archive, member-checked extraction under the declared layout (release single-root — a lone root file IS the tree; `flat` for lazygit's rootless tarball; zip for tree-sitter), probe-verified exact `.local/opt/<tool>`; the `.local/bin/<tool>` link recipes point into the trees |
| `go` | Go toolchain | Download-contract archive form: SHA-256-gated tarball, member-checked single-root extraction, one root stripped, probe-verified exact `.local/opt/go`; the `.local/bin/go` link recipe points into it |
| `node` | nvm, then pinned Node | Download-contract archive form both: exact `.local/opt/nvm` (content probe pins `nvm.sh` bytes — a checkout has no executable to version), then the exact Node tree nested at `.local/opt/nvm/versions/node/v<version>` (probe `bin/node --version`), declared parent-first so the nest extracts into the provisioned nvm tree; the rc loader and `.node-version` recipes are unchanged |
| `typescript` | pnpm | Download-contract archive form: tar.gz `flat` (the standalone tree ships rootless — `pnpm` + `dist/` at the top level), probe-verified exact `.local/opt/pnpm`; the `.local/bin/pnpm` link recipe points into it |
| `fonts` | JetBrainsMono Nerd Font | Download-contract archive form: tar.xz `flat` (the ttf set ships rootless), per-platform `targets` (linux `.local/share/fonts/JetBrainsMonoNerdFont`, darwin `Library/Fonts/JetBrainsMonoNerdFont`); the content probe pins `JetBrainsMonoNerdFont-Regular.ttf` bytes; host cache/registration reads the provisioned directory |
| `secrets` | op | Download-contract zip archive, `flat` layout (`op` + `op.sig`): probe-verified exact `.local/opt/op`; the `.local/bin/op` link recipe points into it; verify only `--version`, never account/vault state |
| `herdr` | Herdr binary | Exact pinned single binary via the download contract → `.local/opt/herdr/bin/herdr` (per-platform SHA-256, mode 0755); the `.local/bin/herdr` link recipe points at it |
| `prompt` | eza, starship | Download-contract archive form per tool (lone-root-file release tarballs — the binary IS the tree), probe-verified exact `.local/opt/<tool>`; the `.local/bin/<tool>` link recipes point into them; starship pinned both hosts, eza linux-only (upstream publishes no darwin_arm64 asset) |
| Engine bootstrap | Neovim | Strip one root; exact `.local/opt/nvim`; no competing package installer |
| Engine file backend | chezmoi | Selected archive member; never package-owned |
| Engine mise contract | The managed tool set (tmux, btop, the erlang/elixir pins) | `MISE_DATA_DIR` under the engine state root; composed `.config/mise/config.toml` (the generation pins its descriptor); PATH symlink `.local/bin/mise` with content-proof absorption of the installer's copy; the installer conf.d fragment is absorbed (deleted) at apply |

Package setup uses checksum-verified provisioning and installed-content comparison;
unchanged installations are retained. Directory specs may declare `ignore` lists of
directory names whose subtrees stay out of staging and installed tree manifests, so
runtime drift inside them is intentionally never repaired; the downloaded archive's
checksum still pins their content. See [lifecycle contracts](capabilities.md#lifecycle-phases),
[installation/prerequisites](../README.md) and [legacy cutover](chezmoi.md#breaking-cutover).

## Bootstrap pin maintenance

`workstation/versions.json` is the single source of truth for the bootstrap
download pins: the `neovim` version plus each platform's `neovim_<plat>_url`
template (`{V}` is substituted with the pinned version at derivation) and
`neovim_<plat>_sha256`. The backend SHA256 values come from the official
v2.72.1 `chezmoi_2.72.1_checksums.txt` release asset. The retired
`workstation/bootstrap/bootstrap.pins` manifest (generated, SHA256-bound
rows over `versions.json`) is gone — bumping a pin means updating
`versions.json` only. The engine derives and validates the records
fail-closed on every bootstrap (version digits/dots, GitHub release path
bound to the pinned version, restricted URL character set, 64-hex digests,
no un-consumed `neovim_*` fields) and re-verifies every digest on every
use; the release refresh passes the derived records to
`bootstrap/install-runtime.sh` as env, and a fresh machine derives them
inline from the same file.

The mise-first installer reads this file with the same fail-closed
one-anchored-match extraction: `mise` plus `mise_<plat>_url`/`_sha256` pin
the manager itself (digest verified, then the `--version` banner asserted,
before anything else runs), and `tmux`/`tmux_mise_backend` plus
`btop`/`btop_mise_backend` pin the first-acquisition sources handed to
`mise install` on Linux; on darwin those pins are skipped — the tools are
host prerequisites there (brew) and the installer banner states the skip
("skipped on darwin: host prerequisites"). Both installers scope every mise
resolution to the checkout's own pins: the toolchain install and the
bootstrap's release build run under an isolated `MISE_CONFIG_DIR`, so the
ambient global config/conf.d (a stale engine-managed `config.toml` from
before the platform-scope contract, for instance) never enters the
acquisition chain — a bare `mise install` provisions every declared tool,
and mise's exec auto-installs declared-but-missing tools, so an
unconditional chain would abort a darwin bootstrap on the linux-only pins.
mise's own backends verify the tool artifacts they fetch;
on Linux the installer then asserts the resolved `tmux -V`/`btop --version`
banners
against the pinned versions. These installer-side records are first
acquisition only — steady-state declarations belong to the engine mise
contract, which owns the binary from the first apply onward.

The engine's mise contract keeps its own pin set alongside the installer's:
`mise_bin_<plat>_url`/`_sha256` pin the RAW release binaries (single-file
pins by choice — the download contract also installs archive trees, but
mise needs exactly one executable, not a tree), consumed by the
engine-owned base package's download contribution into
`.local/opt/mise/<version>/bin/mise`. A mise bump updates both pin sets
(tarball for the installer, raw binary for the engine), the engine's
versioned opt target, and the managed tool set declarations; the applied
generation moves because the composed config descriptor is pinned into it.
Tool state (`MISE_DATA_DIR`) lives under the engine state root
(`.local/state/workstation/mise`) — this mise generation honors
`MISE_DATA_DIR` (the historical `MISE_DATA_HOME` is not read for tool
resolution), and the engine never redirects `XDG_DATA_HOME` in user shells.
Dropping a tool from the declarations leaves its installed version on disk
unrecorded (the record covers the declared set); remove it explicitly if it
must go.

Concurrent runtime installers serialize on `.local/opt/.nvim-bootstrap.lock`;
after interrupted SIGKILL, inspect/recover that lock and any `previous` tree before
retrying. Do not remove a lock while its installer is still running.

## Distro prerequisites

The four host tools every supported platform needs before any provisioning:
`git`, `curl`, and the two extractors the archive pins decompress through —
`xz-utils` for the tar.xz pins, `unzip` for the zip pins (the measured
bare-box story is in the [README](../README.md#prerequisites)). The block
below is the canonical machine-readable form: the engine's bootstrap parses
it fail-closed before provisioning (exactly one `workstation-distro-prereqs`
block in this file, one `<distro package>:<PATH binary>` entry per line,
`#` comments and blank lines allowed, lowercase names, no duplicates), and a
missing tool refuses the bootstrap once, naming the full missing set with
the distro install command derived from the parsed package list. The apply
extraction refusal stays as the fail-closed backstop.

```workstation-distro-prereqs
# <distro package>:<binary probed on PATH>
git:git
curl:curl
xz-utils:xz
unzip:unzip
```

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| Git on Linux (distro) | One of the four distro prerequisites measured on a bare box (git, curl, xz-utils, unzip — see README prerequisites), deliberately unpinned: no first-party static git passes the acquisition audit (upstream git/git ships no release assets; `aqua:git` is not carried by the aqua registry), and the erlang/elixir mise backends clone through git, so it must exist before the toolchain install | `apt install git curl xz-utils unzip` on the fresh box (README prerequisites); `install.sh` verifies git and curl fail-closed, the engine bootstrap verifies the whole set before any provisioning (the machine-readable [block above](#distro-prerequisites) — one refusal naming every missing tool with the install command), and a missing tool at the first `apply` still surfaces as a named extraction refusal (the fail-closed backstop) |
| tmux >=3.2 and btop on macOS; Bash >=5.2 | User/CI unmanaged prerequisites on macOS; no lifecycle OS installs | The tmux binary and btop are contract-managed through the engine mise contract on Linux only (linux-scoped managed tool set, table above); a darwin apply omits the scoped declarations, so the brew prerequisites stand there. darwin acceptance runs in CI. tmux plugin commits/setup are managed separately by the tmux package (`Workstation.Packages.Tmux`, payload `workstation/packages/terminal/tmux/`) |
| C compiler/build tools, Linux fontconfig, macOS Command Line Tools | Parser/application builds and font verification prerequisites | User or CI image; see README |
| ShellCheck | Validation tool supplied by Linux CI image; used wherever available | `.github/scripts/check.sh`; no unpinned lint downloads |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `workstation/packages/editor/nvim/files/.config/nvim/mason-lock.json` — see [Neovim](nvim.md) |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `workstation/packages/editor/nvim/files/.config/nvim/lazy-lock.json` is the engine-pinned baseline; the deployed copy is runtime-extended mutable state — see [Neovim](nvim.md) |
