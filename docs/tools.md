# Pinned host tools

All declared in `home/.chezmoiexternal.toml.tmpl`. Update version, URL, and checksum together.

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| Neovim | 0.12.4 | github.com/neovim/neovim | `.local/opt/nvim` (tree, `archive`) | linux-x86_64, darwin-arm64, darwin-x86_64, windows-arm64, windows-x86_64 |
| ripgrep | 15.2.0 | github.com/BurntSushi/ripgrep | `.local/bin/rg` | all 5 |
| fd | 10.4.2 (darwin-x86_64: 10.3.0 — no newer Intel macOS build published) | github.com/sharkdp/fd | `.local/bin/fd` | all 5 |
| fzf | 0.74.2 | github.com/junegunn/fzf | `.local/bin/fzf` | all 5 |
| lazygit | 0.63.1 | github.com/jesseduffield/lazygit | `.local/bin/lazygit` | all 5 |
| tree-sitter (CLI) | 0.26.11 | github.com/tree-sitter/tree-sitter | `.local/bin/tree-sitter` | all 5 |
| rainfrog | 0.4.4 | github.com/achristmascarl/rainfrog | `.local/bin/rainfrog` | all except windows-arm64 (no upstream build) |
| JetBrainsMono Nerd Font | 3.5.0 | github.com/ryanoasis/nerd-fonts | Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont`; Windows: `AppData/Local/Microsoft/Windows/Fonts/JetBrainsMonoNerdFont` | all 5 |

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| chezmoi itself | Can't provision itself (bootstrapping) | Manual, README.md Install section |
| tmux, TPM-installed plugins | tmux/TPM aren't host-tool binaries in the same sense | `home/.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl`, `home/dot_tmux.conf` |
| Tailscale | Needs a root-level system daemon (`tailscaled` via systemd/launchd/Windows service), not a `.local/bin` binary | Not automated; install manually via the OS package manager if needed |
| 1Password CLI (`op`) | Desktop app CLI-integration needs the official `1password-cli` package; a manually downloaded binary at `.local/bin` shadows it on `PATH` | Not automated; install `1password-cli` via the OS package manager |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `home/dot_config/nvim/mason-lock.json` — see nvim.md |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `home/dot_config/nvim/lazy-lock.json` — see nvim.md |
