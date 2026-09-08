# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS (arm64).

| Property | Value |
| --- | --- |
| Download declarations | `home/.chezmoiexternals/*.toml.tmpl` |
| Shared versions | `home/dot_local/share/workstation/versions.json` |
| Node version | `home/dot_node-version` |
| Update unit | Version, URL, SHA-256 checksum, verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| Neovim | 0.12.4 | github.com/neovim/neovim | `.local/opt/nvim` (tree, `archive`) | linux-x86_64, darwin-arm64 |
| Go | 1.27.1 | go.dev | `.local/opt/go` (tree, `archive`) | linux-x86_64, darwin-arm64 |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (tree, `archive`) | Linux x86_64, macOS ARM64 and x64 |
| Node.js | `home/dot_node-version` (currently 24.19.0) | nodejs.org | `.local/opt/nvm/versions/node/v<version>` | linux-x86_64, darwin-arm64 |
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

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| chezmoi itself | Can't provision itself (bootstrapping) | Manual, README.md Install section |
| tmux, TPM-installed plugins | tmux/TPM aren't host-tool binaries in the same sense | `home/dot_local/share/packages/tmux/init.lua`, `home/dot_tmux.conf` |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `home/dot_config/nvim/mason-lock.json` — see nvim.md |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `home/dot_config/nvim/lazy-lock.json` — see nvim.md |
