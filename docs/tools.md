# Tool inventory

Platforms: linux x86_64 (WSL counts as linux), macOS arm64.

| Property | Value |
| --- | --- |
| Tool sourcing | nixpkgs through the flake's pin-override overlay (`overlays.default`, the `nixpkgs-foundation` input); owning modules assert version floors. The remaining pins declare inline in their owning modules: herdr, the tmux/nunchux checkouts (`fetchFromGitHub`), the hermes checkout (flake input) |
| Versions | The nixpkgs lock is the version surface (`nix flake update` moves the set; a lagging lock dies loudly at the owning module's floor). Inline pins move their owning module's row and consumer together |
| Node version | `pkgs.nodejs_24`; `~/.node-version` derives from the runtime (one source) |
| Update unit | The lock (nixpkgs tools) or the owning module's pin row (inline pins), verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| Neovim | 0.12.x (floor 0.12) | nixpkgs (`modules/editor/editor.nix`) | `.local/bin/nvim`; the language profile composes in the editor module | linux-x86_64, darwin-arm64 |
| Go | 1.26.x (floor 1.26) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| Herdr | 0.9.0 | github.com/herdrdev/herdr | The one inline `fetchurl` pin (no nixpkgs coverage); `.local/bin/herdr` from the store derivation | linux-x86_64, darwin-arm64 |
| Node.js | 24.x (floor: the `pkgs.nodejs_24` class) | nixpkgs (`modules/languages/node/node.nix`) | on PATH via `home.packages`; `~/.node-version` derives from the runtime | linux-x86_64, darwin-arm64 |
| pnpm | 12.x (floor 12) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| ripgrep | 15.2.0+ (floor 15.2.0) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| fd | 10.5.x (floor 10.4.2) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| eza | 0.23.5 | nixpkgs | on PATH; the managed `ls` alias rides the rc fragments | linux-x86_64, darwin-arm64 |
| starship | 1.27.0 | nixpkgs | on PATH; per-shell init + `.config/starship.toml` | linux-x86_64, darwin-arm64 |
| fzf | 0.74.x (floor 0.74.2) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| lazygit | 0.66.x (floor 0.63.1) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| tree-sitter (CLI) | 0.26.x (floor 0.26.11) | nixpkgs | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| harlequin + hsql | 2.16.2 | nixpkgs via the overlay (25.05's package predates hsql) | harlequin + `hsql` in one derivation; the hsql agent skill generated from the derivation at build time | linux-x86_64, darwin-arm64 |
| mise | 2025.5.3 | nixpkgs | on PATH — the binary only: per-project runtime versioning (`mise use`, `.mise.toml`, `mise x`); no managed data dir, no launcher, no activation fragment | linux-x86_64, darwin-arm64 |
| direnv + nix-direnv | 2.36.0 / 3.0.7 | nixpkgs via Home Manager (`programs.direnv`) | `use flake`/`use nix` with the evaluation cache and GC roots; the shell hooks ride the rc fragment lane; complements mise: direnv owns repos with a flake/shell.nix, mise owns repos without nix awareness | linux-x86_64, darwin-arm64 |
| 1Password CLI | 2.41.x | nixpkgs (`modules/secrets/secrets.nix`; unfree — the acceptance is `nix/lib/license.nix`) | `op` on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| Hermes Agent | rev `b23600860f8` + interpreter `pkgs.python314` | github.com/NousResearch/hermes-agent; nixpkgs | Pinned checkout `~/.hermes/hermes-agent` (activation ensure); interpreter at `.local/opt/hermes/python`; launcher at `.local/bin/hermes`; skills as store entry symlinks (`programs.hermes.skills`); extensions into `~/.hermes/plugins`; verify anchor `.local/opt/hermes/pin.json` | linux-x86_64, darwin-arm64 |
| JetBrainsMono Nerd Font | 3.5.0 | nixpkgs (`modules/fonts/fonts.nix`) | linux `.local/share/fonts/JetBrainsMonoNerdFont`; darwin `Library/Fonts/JetBrainsMonoNerdFont`; fontconfig enabled | linux-x86_64, darwin-arm64 |
| nunchux | 3.1.3 | github.com/datamadsen/nunchux | pinned checkout `.tmux/plugins/nunchux` (`fetchFromGitHub`) + the `bin/.platform` marker; package is linux-only | linux-x86_64 |
| tmux | 3.7c | nixpkgs (the system legs' host configuration) | the system legs' tmux package; darwin keeps brew | linux-x86_64 |
| btop | 1.4.7 | nixpkgs (the system legs' host configuration) | same as tmux; darwin keeps brew | linux-x86_64 |
| TPM plugin set | pinned commits | github.com/tmux-plugins/tpm, github.com/2KAbhishek/tmux2k, github.com/tmux-plugins/tmux-yank, github.com/tmux-plugins/tmux-resurrect, github.com/christoomey/vim-tmux-navigator | pinned checkouts `~/.tmux/plugins/<name>`; `~/.tmux/plugins.pins.json` is the verify anchor | linux-x86_64, darwin-arm64 |

## Pin maintenance

The nixpkgs lock is the version surface: `nix flake update` moves the set;
the floors keep a lagging lock loud. Inline pins declare in their owning
modules — one pin, one owner, one surface; a bump moves the row, its hash
and the consumer together. The verify lanes anchor on the deployed
manifests: `.local/opt/hermes/pin.json` (agent),
`.tmux/plugins.pins.json` (terminal).

## Host prerequisites

- **nix** with flakes enabled — host-owned on standalone-HM hosts,
  platform-managed on NixOS and nix-darwin.
- **tailscaled** — host-owned on standalone-HM linux hosts (the substrate
  ships the CLI); system-module-owned on NixOS-WSL and nix-darwin.
- **whiptail** — ships with the substrate (`pkgs.newt`); a bare box before
  its first switch falls back to the detected identity values.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| Git on Linux | Distro-provided; no first-party static git passes the acquisition audit | Distro install; nix hosts carry git in the host configuration |
| tmux >=3.2, btop, Bash >=5.2 on macOS | User/CI prerequisites; no lifecycle OS installs | brew prerequisites on darwin; linux hosts get both through the host configurations |
| C compiler/build tools, Linux fontconfig, macOS CLT | Build and font-verification prerequisites | User or CI image |
| ShellCheck | CI validation tool | `.github/scripts/check.sh` |
| 1Password desktop app + session | Interactive authentication is outside source state | Official app, CLI integration, interactive sign-in |
| Mason-installed LSP servers/formatters/linters | Neovim-internal | `mason-lock.json` — see [Neovim](nvim.md) |
| lazy.nvim plugins | Neovim-internal | `lazy-lock.json` — see [Neovim](nvim.md) |
