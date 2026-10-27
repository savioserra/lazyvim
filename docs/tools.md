# Tool inventory

Supported deployment policy is Linux, WSL-as-Linux, and macOS (arm64).

| Property | Value |
| --- | --- |
| Tool sourcing | nixpkgs — the flake's pin-override overlay (`overlays.default`, the `nixpkgs-foundation` input) carries the version-currency surface, and the owning capability modules assert version FLOORS at the retired download pins' versions (operator ruling 2026-10-27: the download-pin machinery retired — nixpkgs maintains the tools, security backports included, no SHA upkeep). The remaining pins declare inline in their owning modules: herdr (no nixpkgs coverage), the tmux/nunchux checkouts (hash-pinned `fetchFromGitHub`), the hermes-agent checkout (the `hermes-agent` flake input) |
| Shared versions | No shared mirror — the nixpkgs lock is the version surface for the migrated tools (`nix flake update` moves them; a lagging lock dies loudly at the owning module's floor); the remaining pins move their owning module's row and consumer together. The terminal domain additionally deploys `~/.tmux/plugins.pins.json` as its verify lane's anchor |
| Node version | nixpkgs-owned (`pkgs.nodejs_24`); `~/.node-version` is DERIVED from the runtime — one source, never a second literal |
| Update unit | The lock (migrated tools) or the owning module's pin row (remaining pins), verification, this table |

| Tool | Version | Source | Target | Platforms |
| --- | --- | --- | --- | --- |
| Neovim | 0.12.4 (bootstrap pin retired with the inventory) | nixpkgs (`modules/editor/editor.nix`) | nixpkgs neovim surfaced at `.local/bin/nvim`; the language profile composes in the editor module (`lib.generators.toLua`) and deploys with the config tree | linux-x86_64, darwin-arm64 |
| Go | 1.26.x (nixpkgs-owned — the foundation input; floor `1.26` asserted in `modules/languages/go/go.nix`; the retired pin carried 1.27.1, the next lock update raises the set) | nixpkgs | `pkgs.go` on PATH via `home.packages` (the retired `.local/bin/go` store link is gone) | linux-x86_64, darwin-arm64 |
| Herdr | 0.9.0 | github.com/herdrdev/herdr | The ONE remaining download pin (no nixpkgs coverage — upstream ships release binaries only; documented in `modules/agent/agent.nix`), an inline `fetchurl` in the owning module; `.local/bin/herdr` linked straight from the store derivation | linux-x86_64, darwin-arm64 (WSL uses the Linux asset) |
| nvm-sh | retired | — | operator ruling 2026-10-27: nvm retired with the pins machinery — nix owns the runtime (`pkgs.nodejs_24`) and nvm's default-alias bug class dies structurally with it; `.local/opt/nvm` and `.config/shell/nvm.sh` retire through the declared tombstones (`modules/languages/node/node.nix`) | — |
| Node.js | 24.x (nixpkgs-owned — the foundation input; the version class `pkgs.nodejs_24`) | nixpkgs (`modules/languages/node/node.nix`) | node on PATH via `home.packages`; `~/.node-version` derives from the runtime so per-project version tools (mise et al) read the version the generation actually ships | linux-x86_64, darwin-arm64 |
| pnpm | 12.x (nixpkgs-owned — the foundation input; floor `12` asserted in `modules/languages/typescript/typescript.nix`; the retired pin carried 12.14.0) | nixpkgs | `pkgs.pnpm` on PATH via `home.packages` (the retired `.local/bin/pnpm` store link is gone) | linux-x86_64, darwin-arm64 |
| ripgrep | 15.2.0 (nixpkgs-owned — the foundation input; floored at the retired pin's version in `modules/foundation/foundation.nix`) | nixpkgs | on PATH via `home.packages` (the retired `.local/bin/rg` store link is gone) | linux-x86_64, darwin-arm64 |
| fd | 10.5.x (nixpkgs-owned — the foundation input; floored at the retired pin's 10.4.2) | nixpkgs (`modules/foundation/foundation.nix`) | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| eza | 0.23.5 (pin row retired — nixpkgs-owned) | nixpkgs (`modules/foundation/foundation.nix` — the dissolved prompt capability) | nixpkgs eza on PATH; the managed `ls` alias rides the foundation module's rc fragments | linux-x86_64, darwin-arm64 |
| starship | 1.27.0 (pin row retired — nixpkgs-owned) | nixpkgs (`modules/foundation/foundation.nix` — the dissolved prompt capability) | nixpkgs starship on PATH; per-shell init + the lean config at `.config/starship.toml` ride the foundation module | linux-x86_64, darwin-arm64 |
| fzf | 0.74.x (nixpkgs-owned — the foundation input; floored at the retired pin's 0.74.2) | nixpkgs (`modules/foundation/foundation.nix`) | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| lazygit | 0.66.x (nixpkgs-owned — the foundation input; floored at the retired pin's 0.63.1) | nixpkgs (`modules/foundation/foundation.nix`) | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| tree-sitter (CLI) | 0.26.x (nixpkgs-owned — the foundation input; floored at the retired pin's 0.26.11) | nixpkgs (`modules/foundation/foundation.nix`) | on PATH via `home.packages` | linux-x86_64, darwin-arm64 |
| rainfrog | 0.4.4 (retired — replaced by harlequin + hsql) | — | operator ruling 2026-10-22: the download recipe retired; harlequin lands natively with its headless agent CLI | — |
| harlequin + hsql | 2.16.2 (the version shipping hsql) | nixpkgs via the foundation domain's pin surface (the flake's `nixpkgs-foundation` input + `overlays.default`; 25.05's package predates hsql) | nixpkgs harlequin on PATH (the terminal SQL IDE) with `hsql` — its headless agent CLI — in the same derivation; the hsql agent skill is generated from the derivation by `hsql --skill` at build time and serves as a declared entry symlink (`programs.hermes.skills.hsql`), version-matched, offline | linux-x86_64, darwin-arm64 |
| mise (mise-en-place) | 2025.5.3 (pin rides the nixpkgs lock — nixpkgs-owned) | nixpkgs (`modules/foundation/foundation.nix`) | nixpkgs mise on PATH — the binary ONLY: per-project runtime versioning (`mise use`, `.mise.toml`, `mise x`); the substrate owns nothing around it (no managed data dir, no launcher, no activation fragment — shell activation is operator opt-in, its own card if ever) | linux-x86_64, darwin-arm64 |
| direnv + nix-direnv | 2.36.0 / 3.0.7 (pins ride the nixpkgs lock — nixpkgs-owned) | nixpkgs via Home Manager (`modules/foundation/foundation.nix`, `programs.direnv`) | the per-repo environment layer for nix-aware repos: `use flake`/`use nix` with the evaluation cache (`~/.cache/direnv/`) and GC roots (shells survive `nix-collect-garbage` between visits). HM stages the package and sources nix-direnv globally (`~/.config/direnv/lib/hm-nix-direnv.sh`); the shell hooks ride the rc fragment lane (`managed-direnv`/`managed-direnv-zsh` fragments) — HM's `enableBash/enableZshIntegration` are declared false: they write into `programs.bash`/`programs.zsh`, which this substrate never enables (the rc lane is the rendered home.file), so those flags would be silent no-ops. Complements mise: direnv owns repos WITH a flake/shell.nix, mise owns repos WITHOUT nix awareness — a tree carrying both `.envrc` and `.mise.toml` is direnv's, with no activation fight (verified t_d27af1cb) | linux-x86_64, darwin-arm64 |
| 1Password CLI | 2.41.x (nixpkgs-owned — the foundation input; the retired pin carried 2.39.0) | nixpkgs (`modules/secrets/secrets.nix`; the package is unfree — the acceptance is `nix/lib/license.nix`, named and scoped to the one package, imported by every composition root) | `pkgs._1password-cli` on PATH via `home.packages`; verified by the `secrets` capability (`op --version`, never account or vault state) | linux-x86_64, darwin-arm64 |
| Hermes Agent | rev `b23600860f8` (flake input `hermes-agent`, fetchGit rev — surfaced as `outputs.hermesAgentPin` -> `programs.hermes.pin`) + interpreter `pkgs.python314` (nixpkgs-owned via the foundation input; floored at the release the pinned rev's `pm/lock.json` carries — the eval dies loud naming both versions on a mismatch) | github.com/NousResearch/hermes-agent; nixpkgs | Pinned checkout `~/.hermes/hermes-agent` (activation ensure: clone/fetch only when absent or clean-and-behind — the hot-home law: activation mutates it, the file plane never tracks it; the runtime writes into the tree, so a full derivation stays the deferred alternative), interpreter `.local/opt/hermes/python` (the `pkgs.python314` tree claim — the launcher and the verify lane resolve it exactly as before), engine launcher `programs.hermes.package` on PATH as `.local/bin/hermes` (store path, no `../opt` root); declared skills serve as ONE store entry symlink per target profile (`programs.hermes.skills`), gateway extensions link into `~/.hermes/plugins`; verified by `modules/agent/verify/hermes.sh` against the deployed pin manifest `.local/opt/hermes/pin.json` (engine rev + interpreter version; consumer smoke `hermes --version` on every host) | linux-x86_64, darwin-arm64 |
| JetBrainsMono Nerd Font | 3.5.0 (nixpkgs-owned — the foundation input; `pkgs.nerd-fonts.jetbrains-mono`) | nixpkgs (`modules/fonts/fonts.nix`) | the package's font directory deploys at the same per-platform targets the pin tree used — Linux: `.local/share/fonts/JetBrainsMonoNerdFont`; darwin: `Library/Fonts/JetBrainsMonoNerdFont`; fontconfig enabled so `fc-cache` sees it | linux-x86_64, darwin-arm64 |
| nunchux (launcher package; plugin active) | 3.1.3 | github.com/datamadsen/nunchux | pinned checkout `.tmux/plugins/nunchux` (hash-pinned `fetchFromGitHub` declared in `modules/terminal/terminal.nix` at the v3.1.3 commit; carries the repo-tracked binary) + `bin/.platform` marker so upstream's `ensure_binary` never fetches ([tmux](tmux.md)) | linux-amd64 (repo build, content-pinned); package is linux-only (the release-asset checksum rows retired with the inventory — no consumer) |
| tmux (binary) | 3.7c | nixpkgs (host configuration) | The host configuration's tmux package; the historical engine mise-contract declaration is retired (`mise` provider lane refused — toolchains come from nixpkgs); on darwin tmux stays a host prerequisite (brew) | linux-x86_64 |
| btop | 1.4.7 | nixpkgs (host configuration) | Same host-configuration story as the tmux binary (btop ships no darwin release assets); on darwin it stays a host prerequisite (brew) | linux-x86_64 |
| TPM plugin set (tpm, tmux2k, tmux-yank, tmux-resurrect, vim-tmux-navigator) | pinned commits, hash-pinned (`fetchFromGitHub` owner/repo/rev/hash in the terminal capability's module — the un-locked `fetchGit` calls retired) | github.com/tmux-plugins/tpm, github.com/2KAbhishek/tmux2k, github.com/tmux-plugins/tmux-yank, github.com/tmux-plugins/tmux-resurrect, github.com/christoomey/vim-tmux-navigator | substrate-provisioned pinned checkouts `~/.tmux/plugins/<name>` (hermetic, in-store; tpm leads — it must exist before the first tmux start); the same declaration deploys as `~/.tmux/plugins.pins.json` (url + rev rows derived from the same literals) — the verify lane's anchor; verified by `modules/terminal/tmux/verify/tmux.sh` | linux-x86_64, darwin-arm64 |

## Pin maintenance

The nixpkgs lock is the version surface for the migrated tools: a
`nix flake update` moves the whole current set, and the owning capability
modules' floor asserts keep the eval loud if a lock ever lags a floor —
a quiet downgrade of the fleet's tool set is never a silent act. The
substrate has no download machinery left to maintain (the pins library
retired 2026-10-27).

What remains pinned declares inline in its owning module — one pin, one
owner, one surface — and a bump moves the row, its hash and the consumer
together, then switching moves the generation: herdr (the inline
`fetchurl` in `modules/agent/agent.nix`), the tmux/nunchux checkouts
(owner/repo/rev/hash in `modules/terminal/terminal.nix`), and the hermes
checkout (the flake's `hermes-agent` input rev — surfaced as
`outputs.hermesAgentPin`; a rev bump re-derives the interpreter's floor
from the new tree's `pm/lock.json` at eval). The verify lanes anchor on
what was DEPLOYED, never a repo file: the agent domain deploys
`.local/opt/hermes/pin.json`, the terminal domain deploys
`.tmux/plugins.pins.json` beside its checkouts.

The retired acquisition layers (the mise-first installer, the bootstrap
runtime installer, the engine's download/mise/git apply faces, and the
`fetchurl` pin library with its per-platform URL templates, SHA upkeep
and probe gates) died with the engine's write plane and the pins
machinery — there is no installer-side pin set anymore. The historical
`workstation/bootstrap/bootstrap.pins` manifest and the `neovim_*`
bootstrap archive pins retired with the shared inventory.

## Host prerequisites

The substrate has one hard prerequisite; everything else it ships:

- **nix** with flakes enabled — host-owned on standalone-HM legs (the
  daemon rides the install mode: multi-user installs run it via systemd,
  single-user installs need none), platform-managed on NixOS and
  nix-darwin.
- **tailscaled** — host-owned system daemon on standalone-HM linux legs
  (the substrate ships the CLI); system-module-owned on NixOS-WSL and
  nix-darwin legs.
- **whiptail** — ships with the substrate (`pkgs.newt`, foundation): the
  launcher shim's install-time UI. `workstation init` captures the
  machine's identity through whiptail dialogs prefilled with the detected
  values; a bare box before its first switch (whiptail not yet on PATH)
  falls back to the detected values verbatim.

## Not managed here

| Tool | Why | Where it's handled |
| --- | --- | --- |
| Git on Linux (distro) | Deliberately unpinned: no first-party static git passes the acquisition audit (upstream git/git ships no release assets; `aqua:git` is not carried by the aqua registry) | Distro install on checkout hosts; nix hosts carry git in the host configuration |
| tmux >=3.2 and btop on macOS; Bash >=5.2 | User/CI unmanaged prerequisites on macOS; no lifecycle OS installs | Linux hosts get both through the host configurations (nixpkgs); the brew prerequisites stand on darwin. darwin acceptance runs in CI. tmux plugin commits/setup are managed by the terminal capability's module (`modules/terminal/`) |
| C compiler/build tools, Linux fontconfig, macOS Command Line Tools | Parser/application builds and font verification prerequisites | User or CI image; see README |
| ShellCheck | Validation tool supplied by Linux CI image; used wherever available | `.github/scripts/check.sh`; no unpinned lint downloads |
| 1Password desktop app and account session | User application and interactive authentication are outside source state | Install the official app, enable CLI integration, and sign in interactively |
| Mason-installed LSP servers/formatters/linters | Neovim-internal package manager, not a host binary | `zapling/mason-lock.nvim`, `modules/editor/nvim/files/.config/nvim/mason-lock.json` — see [Neovim](nvim.md) |
| lazy.nvim-installed Neovim plugins | Neovim-internal package manager | `modules/editor/nvim/files/.config/nvim/lazy-lock.json` is the substrate-pinned baseline; the deployed copy is runtime-extended mutable state — see [Neovim](nvim.md) |
