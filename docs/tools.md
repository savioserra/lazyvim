# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS (arm64).

| Property | Value |
| --- | --- |
| Pin sourcing | The owning capability module under `modules/<domain>/` (pins ride the module tree; `workstation/versions.json` is the interim inventory) — the substrate renders every download pin as a checksummed `fetchurl` derivation; the nixpkgs set owns toolchains |
| Shared versions, URL templates and SHA-256 (the verify lane's mirror) | `workstation/versions.json` |
| Node version | `modules/languages/node/files/.node-version` |
| Update unit | Version, URL, SHA-256 checksum, verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| Neovim | 0.12.4 (pin recorded as inventory) | nixpkgs (`modules/editor/editor.nix`; the historical bootstrap archive pin is retired) | nixpkgs neovim surfaced at `.local/bin/nvim`; the language profile composes in the editor module (`lib.generators.toLua`) and deploys with the config tree | linux-x86_64, darwin-arm64 |
| Go | 1.27.1 | go.dev | Pinned archive tree from `nix/lib/pins.nix` (probe `bin/go version`), `.local/bin/go` linked straight from the store tree | linux-x86_64, darwin-arm64 |
| Herdr | 0.9.0 | github.com/herdrdev/herdr | Archive-less pin (the fetched bytes ARE the binary), linked straight from the store derivation at `.local/bin/herdr` | linux-x86_64, darwin-arm64 (WSL uses the Linux asset) |
| nvm-sh | 0.40.4 | github.com/nvm-sh/nvm | `.local/opt/nvm` (pinned archive tree, content probe `nvm.sh`; `node` package) | linux-x86_64, darwin-arm64 |
| Node.js | `modules/languages/node/files/.node-version` (currently 24.19.0) | nodejs.org | `.local/opt/nvm/versions/node/v<version>` (pinned archive tree, probe `bin/node --version`; nested in the provisioned nvm tree, declared parent-first) | linux-x86_64, darwin-arm64 |
| pnpm | 12.14.0 | github.com/pnpm/pnpm | Pinned archive (`flat` layout — the rootless `pnpm` + `dist/` standalone tree, probe `pnpm --version`), `.local/bin/pnpm` linked straight from the store tree (`typescript` package) | linux-x86_64, darwin-arm64 |
| ripgrep | 15.2.0 | github.com/BurntSushi/ripgrep | Pinned archive from `nix/lib/pins.nix` (probe `rg --version`), `.local/bin/rg` linked straight from the store tree | linux-x86_64, darwin-arm64 |
| fd | 10.4.2 | github.com/sharkdp/fd | Pinned archive from `nix/lib/pins.nix` (probe `fd --version`), `.local/bin/fd` linked straight from the store tree | linux-x86_64, darwin-arm64 |
| eza | 0.23.5 (pin row retired — nixpkgs-owned) | nixpkgs (`modules/foundation/foundation.nix` — the dissolved prompt capability) | nixpkgs eza on PATH; the managed `ls` alias rides the foundation module's rc fragments | linux-x86_64, darwin-arm64 |
| starship | 1.27.0 (pin row retired — nixpkgs-owned) | nixpkgs (`modules/foundation/foundation.nix` — the dissolved prompt capability) | nixpkgs starship on PATH; per-shell init + the lean config at `.config/starship.toml` ride the foundation module | linux-x86_64, darwin-arm64 |
| fzf | 0.74.2 | github.com/junegunn/fzf | Pinned archive from `nix/lib/pins.nix` (the lone root file IS the tree, probe `fzf --version`), `.local/bin/fzf` linked straight from the store tree | linux-x86_64, darwin-arm64 |
| lazygit | 0.63.1 | github.com/jesseduffield/lazygit | Pinned archive from `nix/lib/pins.nix` (`flat` rootless layout, exec probe carrying the pinned release metadata), `.local/bin/lazygit` linked straight from the store tree | linux-x86_64, darwin-arm64 |
| tree-sitter (CLI) | 0.26.11 | github.com/tree-sitter/tree-sitter | Pinned zip archive from `nix/lib/pins.nix` (probe `tree-sitter --version`), `.local/bin/tree-sitter` linked straight from the store tree | linux-x86_64, darwin-arm64 |
| rainfrog | 0.4.4 (retired — replaced by harlequin + hsql) | — | operator ruling 2026-10-22: the download recipe retired; harlequin lands natively with its headless agent CLI | — |
| harlequin + hsql | 2.16.2 (the version shipping hsql) | nixpkgs via the foundation domain's pin surface (the flake's `nixpkgs-foundation` input + `overlays.default`; 25.05's package predates hsql) | nixpkgs harlequin on PATH (the terminal SQL IDE) with `hsql` — its headless agent CLI — in the same derivation; the hsql agent skill provisions at activation, version-matched, offline | linux-x86_64, darwin-arm64 |
| 1Password CLI | 2.39.0 | cache.agilebits.com | Pinned zip archive from `nix/lib/pins.nix` (`flat` layout — `op` + `op.sig`, probe `op --version`), `.local/bin/op` linked straight from the store tree; verified by the `secrets` capability | linux-x86_64, darwin-arm64 |
| Hermes Agent | commit `b23600860f8` (git pin, `hermes_agent_git_commit`) + python-build-standalone `3.14.7` (archive pin, `hermes_python` — the URL carries the real `20260901` release tag and the probe gates it at BUILD time; the release hermes-agent's `pm/lock.json` carries at the commit) | github.com/NousResearch/hermes-agent; github.com/astral-sh/python-build-standalone | Pinned checkout `~/.hermes/hermes-agent` (activation ensure: clone/fetch only when absent or clean-and-behind — the hot-home law: activation mutates it, the file plane never tracks it), pinned interpreter `.local/opt/hermes/python` (store tree from `nix/lib/pins.nix`, probe `bin/python3 --version`), engine launcher surfaced as `.local/bin/hermes` (store path, no `../opt` root); managed skills are declared store-path leaves (`workstation.agent.skills`); verified by `modules/agent/verify/hermes.sh` (consumer smoke `hermes --version` on every host) | linux-x86_64, darwin-arm64 |
| JetBrainsMono Nerd Font | 3.5.0 | github.com/ryanoasis/nerd-fonts | Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont` | linux-x86_64, darwin-arm64 |
| nunchux (launcher package; plugin active) | 3.1.3 | github.com/datamadsen/nunchux | pinned checkout `.tmux/plugins/nunchux` (git pin at the v3.1.3 commit; carries the repo-tracked binary) + `bin/.platform` marker so upstream's `ensure_binary` never fetches ([tmux](tmux.md)) | linux-amd64 (repo build, content-pinned); package is linux-only, darwin release pin recorded as inventory |
| tmux (binary) | 3.7c | nixpkgs (host configuration) | The host configuration's tmux package; the historical engine mise-contract declaration is retired (`mise` provider lane refused — toolchains come from nixpkgs); on darwin tmux stays a host prerequisite (brew) | linux-x86_64 |
| btop | 1.4.7 | nixpkgs (host configuration) | Same host-configuration story as the tmux binary (btop ships no darwin release assets); on darwin it stays a host prerequisite (brew) | linux-x86_64 |
| TPM plugin set (tpm, tmux2k, tmux-yank, tmux-resurrect, vim-tmux-navigator) | pinned commits ([tmux](tmux.md) Plugin pins) | github.com/tmux-plugins/tpm, github.com/2KAbhishek/tmux2k, github.com/tmux-plugins/tmux-yank, github.com/tmux-plugins/tmux-resurrect, github.com/christoomey/vim-tmux-navigator | substrate-provisioned pinned checkouts `~/.tmux/plugins/<name>` (git pins in the terminal capability's module, frozen as store checkouts; tpm leads — it must exist before the first tmux start); verified by `modules/terminal/tmux/verify/tmux.sh` | linux-x86_64, darwin-arm64 |

## Pin maintenance

The package manifests are canonical: every download pin carries its version,
URL and SHA-256 beside its payloads, and the substrate renders each as a
checksummed derivation — the store, not the home, is where bytes are
verified. `workstation/versions.json` mirrors the pins for the verify lane:
the capability verify scripts (`modules/*/verify/*.sh`) compare
the deployed tool's version banner against the recorded pin on every host.
A pin bump means updating the owning capability's module pin and its
`versions.json` mirror row, and switching: the generation moves because the
derivations move.

The retired acquisition layer (the mise-first installer, the bootstrap
runtime installer, the engine's download/mise/git apply faces) died with
the engine's write plane — there is no installer-side pin set anymore. The
historical `workstation/bootstrap/bootstrap.pins` manifest and the
`neovim_*` bootstrap archive pins survive only as recorded inventory.

## Distro prerequisites (checkout hosts)

Building the release on a checkout host (no nix) needs the four host tools:
`git`, `curl`, and the two extractors the archive pins decompress through —
`xz-utils` for the tar.xz pins, `unzip` for the zip pins (the measured
bare-box story is in the [README](../README.md#prerequisites)):

```sh
apt install git curl xz-utils unzip   # Debian/Ubuntu
```

Nix hosts need none of these: the store builds are self-contained.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| Git on Linux (distro) | One of the four checkout-host prerequisites (git, curl, xz-utils, unzip — see above), deliberately unpinned: no first-party static git passes the acquisition audit (upstream git/git ships no release assets; `aqua:git` is not carried by the aqua registry) | Distro install on checkout hosts; nix hosts carry git in the host configuration |
| tmux >=3.2 and btop on macOS; Bash >=5.2 | User/CI unmanaged prerequisites on macOS; no lifecycle OS installs | Linux hosts get both through the host configurations (nixpkgs); the brew prerequisites stand on darwin. darwin acceptance runs in CI. tmux plugin commits/setup are managed by the terminal capability's module (`modules/terminal/`) |
| C compiler/build tools, Linux fontconfig, macOS Command Line Tools | Parser/application builds and font verification prerequisites | User or CI image; see README |
| ShellCheck | Validation tool supplied by Linux CI image; used wherever available | `.github/scripts/check.sh`; no unpinned lint downloads |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `modules/editor/nvim/files/.config/nvim/mason-lock.json` — see [Neovim](nvim.md) |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `modules/editor/nvim/files/.config/nvim/lazy-lock.json` is the engine-pinned baseline; the deployed copy is runtime-extended mutable state — see [Neovim](nvim.md) |
