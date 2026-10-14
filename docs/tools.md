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
| Go | 1.27.1 | go.dev | `.local/opt/go` (exact tree, `go` setup) | linux-x86_64, darwin-arm64 |
| Herdr | 0.9.0 | github.com/herdrdev/herdr | `.local/opt/herdr/bin/herdr` (`herdr` setup) + `.local/bin/herdr` link | linux-x86_64, darwin-arm64 (WSL uses the Linux asset) |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (non-exact tree, `node` setup) | linux-x86_64, darwin-arm64 |
| Node.js | `workstation/packages/languages/node/files/.node-version` (currently 24.19.0) | nodejs.org | `.local/opt/nvm/versions/node/v<version>` (non-exact, `node` setup) | linux-x86_64, darwin-arm64 |
| ripgrep | 15.2.0 | github.com/BurntSushi/ripgrep | `.local/bin/rg` | linux-x86_64, darwin-arm64 |
| fd | 10.4.2 | github.com/sharkdp/fd | `.local/bin/fd` | linux-x86_64, darwin-arm64 |
| fzf | 0.74.2 | github.com/junegunn/fzf | `.local/bin/fzf` | linux-x86_64, darwin-arm64 |
| lazygit | 0.63.1 | github.com/jesseduffield/lazygit | `.local/bin/lazygit` | linux-x86_64, darwin-arm64 |
| tree-sitter (CLI) | 0.26.11 | github.com/tree-sitter/tree-sitter | `.local/bin/tree-sitter` | linux-x86_64, darwin-arm64 |
| rainfrog | 0.4.4 | github.com/achristmascarl/rainfrog | `.local/bin/rainfrog` | linux-x86_64, darwin-arm64 |
| 1Password CLI | 2.39.0 | cache.agilebits.com | `.local/bin/op`; verified by the `secrets` capability | linux-x86_64, darwin-arm64 |
| Hermes Agent | commit `46d7718a52` (git pin, `hermes_agent_git_commit`) | github.com/NousResearch/hermes-agent | pinned checkout `~/.hermes/hermes-agent` (git recipe); launcher `~/.hermes/hermes-agent/.hermes/bin/hermes`; verified by `packages/agent/verify/hermes.sh` | linux-x86_64, darwin-arm64 |
| JetBrainsMono Nerd Font | 3.5.0 | github.com/ryanoasis/nerd-fonts | Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont` | linux-x86_64, darwin-arm64 |
| nunchux (launcher package; plugin active) | 3.1.3 | github.com/datamadsen/nunchux | pinned checkout `.tmux/plugins/nunchux` (git recipe at the v3.1.3 commit; carries the repo-tracked binary) + `bin/.platform` marker so upstream's `ensure_binary` never fetches ([tmux](tmux.md)) | linux-amd64 (repo build, content-pinned); package is linux-only, darwin release pin recorded as inventory |
| mise | 2026.10.8 | github.com/jdx/mise | `.local/bin/mise` (installer first acquisition; activated in shells by the managed mise fragment) | linux-x86_64, darwin-arm64 |
| tmux (binary) | 3.7c | `aqua:tmux/tmux-builds` via mise | mise-managed first acquisition; resolvable through the mise activation fragment plus the installer-written `~/.config/mise/conf.d/workstation-bootstrap.toml`. macOS keeps host tmux | linux-x86_64 (darwin host prerequisite) |
| btop | 1.4.7 | `github:aristocratos/btop` via mise | mise-managed first acquisition, same resolution path as the tmux binary. macOS keeps host btop | linux-x86_64 (darwin host prerequisite) |
| TPM plugin set (tpm, tmux2k, tmux-yank, tmux-resurrect, vim-tmux-navigator) | pinned commits ([tmux](tmux.md) Plugin pins) | github.com/tmux-plugins/tpm, github.com/2KAbhishek/tmux2k, github.com/tmux-plugins/tmux-yank, github.com/tmux-plugins/tmux-resurrect, github.com/christoomey/vim-tmux-navigator | engine-provisioned pinned checkouts `~/.tmux/plugins/<name>` (git recipes in the tmux package manifest; tpm leads — it must exist before the first tmux start); verified by `packages/tmux/verify/tmux.sh` | linux-x86_64, darwin-arm64 |

## Provisioning ownership

| Owner | Setup assets | Layout policy |
| --- | --- | --- |
| `foundation` | rg, fd, fzf, lazygit, tree-sitter, rainfrog | Selected archive members → `.local/bin`, mode 0755; no parent-directory replacement |
| `go` | Go toolchain | Strip one archive root; exact `.local/opt/go` |
| `node` | nvm, then pinned Node | Strip one root each; non-exact overlays preserve aliases, other Node versions and unrelated global npm packages; `node_modules` stays manifest-ignored (checksum-pinned at download) |
| `fonts` | JetBrainsMono Nerd Font | Exact font-only directory, no root stripping; provision before host cache/registration |
| `secrets` | op | ZIP member `op` → `.local/bin/op`, mode 0755; verify only `--version`, never account/vault state |
| Engine bootstrap | Neovim | Strip one root; exact `.local/opt/nvim`; no competing package installer |
| Engine file backend | chezmoi | Selected archive member; never package-owned |

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
`mise install`. mise's own backends verify the tool artifacts they fetch;
the installer then asserts the resolved `tmux -V`/`btop --version` banners
against the pinned versions. These installer-side records are first
acquisition only — steady-state declarations belong to the engine mise
contract.

Concurrent runtime installers serialize on `.local/opt/.nvim-bootstrap.lock`;
after interrupted SIGKILL, inspect/recover that lock and any `previous` tree before
retrying. Do not remove a lock while its installer is still running.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| Git on Linux (distro) | The single distro prerequisite, deliberately unpinned: no first-party static git passes the acquisition audit (upstream git/git ships no release assets; `aqua:git` is not carried by the aqua registry), and the erlang/elixir mise backends clone through git, so it must exist before the toolchain install | One `apt install git` on the fresh box (README prerequisites); `install.sh` verifies it fail-closed and refuses without it |
| tmux >=3.2 and btop on macOS; Bash >=5.2 | User/CI unmanaged prerequisites on macOS; no lifecycle OS installs | The tmux binary and btop are mise-first-acquired on Linux (table above); tmux plugin commits/setup are managed separately by the tmux package (`Workstation.Packages.Tmux`, payload `workstation/packages/terminal/tmux/`) |
| C compiler/build tools, Linux fontconfig, macOS Command Line Tools | Parser/application builds and font verification prerequisites | User or CI image; see README |
| ShellCheck | Validation tool supplied by Linux CI image; used wherever available | `.github/scripts/check.sh`; no unpinned lint downloads |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `workstation/packages/editor/nvim/files/.config/nvim/mason-lock.json` — see [Neovim](nvim.md) |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `workstation/packages/editor/nvim/files/.config/nvim/lazy-lock.json` is the engine-pinned baseline; the deployed copy is runtime-extended mutable state — see [Neovim](nvim.md) |
