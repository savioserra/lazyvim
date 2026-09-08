# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS (arm64).

| Property | Value |
| --- | --- |
| Download declarations | `chezmoi/.chezmoiexternals/*.toml.tmpl` |
| Shared versions | `workstation/versions.json` |
| Node version | `chezmoi/dot_node-version` |
| Update unit | Version, URL, SHA-256 checksum, verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| chezmoi backend | 2.72.1 | github.com/twpayne/chezmoi | `.local/opt/chezmoi/bin/chezmoi` (engine-owned) | linux-x86_64, darwin-arm64 |
| Neovim | 0.12.4 | github.com/neovim/neovim | `.local/opt/nvim` (tree, `archive`) | linux-x86_64, darwin-arm64 |
| Go | 1.27.1 | go.dev | `.local/opt/go` (tree, `archive`) | linux-x86_64, darwin-arm64 |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (tree, `archive`) | Linux x86_64, macOS ARM64 and x64 |
| Node.js | `chezmoi/dot_node-version` (currently 24.19.0) | nodejs.org | `.local/opt/nvm/versions/node/v<version>` | linux-x86_64, darwin-arm64 |
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

The runtime and backend pins are canonical in `workstation/versions.json`.
The backend SHA256 values come from the official v2.72.1
`chezmoi_2.72.1_checksums.txt` release asset. Bootstrap installs Neovim in POSIX
shell before Lua provisions this backend; it does not use a PATH chezmoi.
`workstation/bootstrap/bootstrap.pins` is a generated, SHA256-bound projection:
regenerate/check with pinned `nvim -l workstation/bootstrap/generate.lua [--check]`.
Fresh bootstrap needs shell, curl with HTTPS, tar/gzip, SHA256 tooling
(`sha256sum` on Linux, `shasum` on macOS), and ordinary Unix filesystem tools;
no Node, Python, jq, or system Neovim is required. Concurrent runtime installers
serialize on `.local/opt/.nvim-bootstrap.lock`; an interrupted SIGKILL requires
inspection/recovery of that lock and any `previous` tree before retrying.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| tmux, TPM-installed plugins | tmux/TPM aren't host-tool binaries in the same sense | `workstation/packages/tmux/init.lua`, `chezmoi/dot_tmux.conf` |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `chezmoi/dot_config/nvim/mason-lock.json` — see nvim.md |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `chezmoi/dot_config/nvim/lazy-lock.json` — see nvim.md |
