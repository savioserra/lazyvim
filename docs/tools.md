# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS. Native-Windows entries below are retained removal inventory during milestone 1 and do not constitute support.

| Property | Value |
| --- | --- |
| Download declarations | `home/.chezmoiexternals/*.toml.tmpl` |
| Shared versions | `home/dot_local/share/workstation/versions.json` |
| Node version | `home/dot_node-version` |
| Update unit | Version, URL, SHA-256 checksum, verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| Neovim | 0.12.4 | github.com/neovim/neovim | `.local/opt/nvim` (tree, `archive`) | linux-x86_64, darwin-arm64, darwin-x86_64, windows-arm64, windows-x86_64 |
| Go | 1.27.0 | go.dev | `.local/opt/go` (tree, `archive`) | linux-x86_64, darwin-arm64, darwin-x86_64, windows-arm64, windows-x86_64 |
| nvm-windows | 1.2.2 | github.com/coreybutler/nvm-windows | `.local/opt/nvm-windows` (tree, `archive`) | Windows ARM64 and x64 |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (tree, `archive`) | Linux x86_64, macOS ARM64 and x64 |
| Node.js | `home/dot_node-version` (currently 24.19.0) | nodejs.org | Windows: `.local/opt/nvm-windows/v<version>`; Unix: `.local/opt/nvm/versions/node/v<version>` | all 5 |
| ripgrep | 15.2.0 | github.com/BurntSushi/ripgrep | `.local/bin/rg` | all 5 |
| fd | 10.4.2 (darwin-x86_64: 10.3.0 — no newer Intel macOS build published) | github.com/sharkdp/fd | `.local/bin/fd` | all 5 |
| fzf | 0.74.2 | github.com/junegunn/fzf | `.local/bin/fzf` | all 5 |
| lazygit | 0.63.1 | github.com/jesseduffield/lazygit | `.local/bin/lazygit` | all 5 |
| tree-sitter (CLI) | 0.26.11 | github.com/tree-sitter/tree-sitter | `.local/bin/tree-sitter` | all 5 |
| rainfrog | 0.4.4 | github.com/achristmascarl/rainfrog | `.local/bin/rainfrog` | all except windows-arm64 (no upstream build) |
| 1Password CLI | 2.39.0 | cache.agilebits.com | `.local/bin/op`; verified by the `secrets` capability | all 5; Windows ARM64 uses the x64 build |
| pi coding agent | 0.84.3 | npm: `@earendil-works/pi-coding-agent` | Managed Node global prefix | all 5 |
| pi-subagents | 0.56.0 | npm: `pi-subagents` (`nicobailon/pi-subagents`) | `.pi/agent/npm/node_modules/pi-subagents` | all 5 |
| JetBrainsMono Nerd Font | 3.5.0 | github.com/ryanoasis/nerd-fonts | Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont`; Windows: `AppData/Local/Microsoft/Windows/Fonts/JetBrainsMonoNerdFont` | all 5 |

## GoAkt service source dependency

The sole nested service module under `services/subagents/` uses the managed Go 1.27.0 toolchain and exactly pins `github.com/tochemey/goakt/v4` v4.5.2. Its reproducible schema check uses SHA-256-pinned protoc 33.5 archives, module-locked protoc-gen-go 1.36.12, lockfile-pinned protoc-gen-es 2.11.0, and lockfile-pinned `tsx` to execute the generated descriptor. Chezmoi setup builds the reviewed daemon and clientctl into `~/.local/bin` with `go build -mod=readonly` and activates only the owner user service. The source-managed hosted bridge and actor client pin `@bufbuild/protobuf@2.11.0` and exact registry integrity in local locks. See [`subagents.md`](subagents.md).

## Tmux subagent renderer dependencies

The source-managed extension pins `xstate@5.32.6` and `terminal-kit@3.1.4` with exact registry integrities in both `home/dot_local/share/workstation/versions.json` and the extension `package-lock.json`. The owning workstation package installs production dependencies with `npm ci --omit=dev --ignore-scripts --no-audit --no-fund`; no native module or target-host compiler is permitted. The reviewed feature gate is enabled for clienting, but it remains inert until chezmoi apply writes its matching activation attestation and `/reload` completes as a separate step.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| chezmoi itself | Can't provision itself (bootstrapping) | Manual, README.md Install section |
| tmux, TPM-installed plugins | tmux/TPM aren't host-tool binaries in the same sense | `home/dot_local/share/packages/tmux/init.lua`, `home/dot_tmux.conf` |
| Tailscale | Needs a root-level system daemon (`tailscaled` via systemd/launchd/Windows service), not a `.local/bin` binary | Not automated; install manually via the OS package manager if needed |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `home/dot_config/nvim/mason-lock.json` — see nvim.md |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `home/dot_config/nvim/lazy-lock.json` — see nvim.md |
