# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS (arm64).

| Property | Value |
| --- | --- |
| Download operations | Owning `workstation/packages/<name>/` setup; Neovim bootstrap and engine-owned chezmoi backend |
| Shared versions, URL templates and SHA-256 | `workstation/versions.json` |
| Node version | `workstation/packages/node/files/.node-version` |
| Update unit | Version, URL, SHA-256 checksum, verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| chezmoi backend | 2.72.1 | github.com/twpayne/chezmoi | `.local/opt/chezmoi/bin/chezmoi` (engine-owned) | linux-x86_64, darwin-arm64 |
| Neovim | 0.12.4 | github.com/neovim/neovim | `.local/opt/nvim` (exact tree, engine bootstrap) | linux-x86_64, darwin-arm64 |
| Go | 1.27.1 | go.dev | `.local/opt/go` (exact tree, `go` setup) | linux-x86_64, darwin-arm64 |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (non-exact tree, `node` setup) | linux-x86_64, darwin-arm64 |
| Node.js | `workstation/packages/node/files/.node-version` (currently 24.19.0) | nodejs.org | `.local/opt/nvm/versions/node/v<version>` (non-exact, `node` setup) | linux-x86_64, darwin-arm64 |
| ripgrep | 15.2.0 | github.com/BurntSushi/ripgrep | `.local/bin/rg` | linux-x86_64, darwin-arm64 |
| fd | 10.4.2 | github.com/sharkdp/fd | `.local/bin/fd` | linux-x86_64, darwin-arm64 |
| fzf | 0.74.2 | github.com/junegunn/fzf | `.local/bin/fzf` | linux-x86_64, darwin-arm64 |
| lazygit | 0.63.1 | github.com/jesseduffield/lazygit | `.local/bin/lazygit` | linux-x86_64, darwin-arm64 |
| tree-sitter (CLI) | 0.26.11 | github.com/tree-sitter/tree-sitter | `.local/bin/tree-sitter` | linux-x86_64, darwin-arm64 |
| rainfrog | 0.4.4 | github.com/achristmascarl/rainfrog | `.local/bin/rainfrog` | linux-x86_64, darwin-arm64 |
| 1Password CLI | 2.39.0 | cache.agilebits.com | `.local/bin/op`; verified by the `secrets` capability | linux-x86_64, darwin-arm64 |
| pi coding agent | 0.85.1 | npm: `@earendil-works/pi-coding-agent` | Managed Node global prefix | linux-x86_64, darwin-arm64 |
| pi-subagents | 0.66.0 | npm: `pi-subagents` | Pi package install under the Pi agent directory | linux-x86_64, darwin-arm64 |
| pi-web-access | 0.28.0 | npm: `pi-web-access` | Pi package install under the Pi agent directory | linux-x86_64, darwin-arm64 |
| pi-ntfy-notifier | 0.3.0 | Source-managed extension in this repo | `.pi/agent/extensions/ntfy-notifier` | linux-x86_64, darwin-arm64 |
| JetBrainsMono Nerd Font | 3.5.0 | github.com/ryanoasis/nerd-fonts | Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont` | linux-x86_64, darwin-arm64 |

## Provisioning ownership

| Owner | Setup assets | Layout policy |
| --- | --- | --- |
| `foundation` | rg, fd, fzf, lazygit, tree-sitter, rainfrog | Selected archive members → `.local/bin`, mode 0755; no parent-directory replacement |
| `go` | Go toolchain | Strip one archive root; exact `.local/opt/go` |
| `node` | nvm, then pinned Node | Strip one root each; non-exact overlays preserve aliases, other Node versions and unrelated global npm packages |
| `fonts` | JetBrainsMono Nerd Font | Exact font-only directory, no root stripping; provision before host cache/registration |
| `secrets` | op | ZIP member `op` → `.local/bin/op`, mode 0755; verify only `--version`, never account/vault state |
| Engine bootstrap | Neovim | Strip one root; exact `.local/opt/nvim`; no competing package installer |
| Engine file backend | chezmoi | Selected archive member; never package-owned |

Package setup uses checksum-verified provisioning and installed-content comparison;
unchanged installations are retained. See [lifecycle contracts](capabilities.md#lifecycle-phases),
[installation/prerequisites](../README.md) and [legacy cutover](chezmoi.md#breaking-cutover).

## Bootstrap pin maintenance

The backend SHA256 values come from the official v2.72.1
`chezmoi_2.72.1_checksums.txt` release asset. `workstation/bootstrap/bootstrap.pins`
is a generated, SHA256-bound projection of `workstation/versions.json`, not a
second hand-maintained source. Regenerate/check with pinned
`nvim -l workstation/bootstrap/generate.lua [--check]`.

Concurrent runtime installers serialize on `.local/opt/.nvim-bootstrap.lock`;
after interrupted SIGKILL, inspect/recover that lock and any `previous` tree before
retrying. Do not remove a lock while its installer is still running.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| Git, tmux >=3.2, Bash >=5.2 | User/CI unmanaged prerequisites; no lifecycle OS installs | tmux plugin commits/setup are managed separately by `workstation/packages/tmux/init.lua` |
| C compiler/build tools, Linux fontconfig, macOS Command Line Tools | Parser/application builds and font verification prerequisites | User or CI image; see README |
| ShellCheck | Validation tool supplied by Linux CI image; used wherever available | `.github/scripts/check.sh`; no unpinned lint downloads |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `workstation/packages/nvim/files/.config/nvim/mason-lock.json` — see [Neovim](nvim.md) |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `workstation/packages/nvim/files/.config/nvim/lazy-lock.json` is the engine-pinned baseline; the deployed copy is runtime-extended mutable state — see [Neovim](nvim.md) |
