# The endgame: the repo's final shape

The workstation is a **nixpkgs-native monorepo**. There is no engine: no
resident daemon, no wire protocol, no TUI, no Elixir plane, no release to
build or stage. The capability modules declare; home-manager renders; two
small shell clients (the launcher shim and the switch driver) are the whole
operator surface; `nix eval` answers every question about the declared
state. This document is the structure's home — the shape lives here, not in
board comments.

## The final folder structure

| Path | Role |
| --- | --- |
| `flake.nix`, `flake.lock` | The one entry point: inputs framed per domain (each domain owns its pin surface; `follows` dedupes shared nixpkgs/HM), the declared-state report verbs, the host legs, the mesh outputs |
| `modules/<domain>/` | One directory per capability domain — the domain's module file AND the bytes it deploys, co-located: `modules/editor/{editor.nix, nvim/}`, `modules/terminal/{terminal.nix, tmux/, nunchux/}`, `modules/theme/{theme.nix, tokens.nix, tokens.lua}`, `modules/foundation/`, `modules/languages/{node,elixir,typescript,go}/`, `modules/agent/`, `modules/fonts/`, `modules/secrets/`. Adding a capability is adding one directory |
| `nix/` | Shared substrate infrastructure, no capability of its own: `report.nix` (the declared-state fold), `lib/capabilities.nix` (the registry walk), `lib/pins.nix` (the declared pins' shared HOW: fetch/layout/probe machinery, the claim composition), `workstation-switch.nix` (the write plane), `modules/` (the home leg, the system leg, the host-identity options) |
| `hosts/{wsl,mac}/` | The two target legs (WSL counted under linux). `hosts/<host>/default.nix` is the ONLY place a host's identity is written |
| `bin/workstation` | The launcher shim: the whole client (POSIX sh). Reads are `nix eval`s over `workstation.report.<verb>`; writes delegate to the staged `workstation-switch`. The home lane stages the same bytes as a derivation onto the profile PATH |
| `tests/` | `tests/nix/` (the VM proof host: `vm-host.nix`, `vm-home.nix`, `vm-e2e.nix`, `run-vm.sh`) — behavioral acceptance |
| `docs/` | The references; this file is the structure's anchor |
| `.github/` | The static check battery, the CI (static + nix-eval jobs), tagged source archives |

### Flake outputs (locked)

`workstation.report` (the read verbs: `status`, `plan`, `capabilities` —
scope with an attrpath), `homeManagerModules.workstation`,
`homeConfigurations` (the linux leg + the VM persona),
`darwinConfigurations` (the mac leg), `nixosConfigurations.wsl`,
`nixosConfigurations.vm-test`, `overlays.default` (pin overrides ONLY),
`workstationTheme.lib`, `hermesSkills`, `hermesAgentPin`.

## The invariants

- **Two targets.** mac and linux; WSL is linux. No distro-named legs, no
  arch/omarchy references anywhere.
- **Identity is declared once per host.** `workstation.host.{name, user,
  homeDirectory, tailscale.fqdn}` — written only in
  `hosts/<host>/default.nix`; tailscale, the dashboard binding and the
  flake's rebuild keys derive from it. The identity gate in `check.sh`
  reds on personal strings anywhere else.
- **The filesystem is the capability registry.** No central catalog, no
  manifests: the walk (`nix/lib/capabilities.nix`) discovers
  `modules/<domain>/`, and the report fold evaluates each capability once
  against home-manager. Options are domain-level (`workstation.<domain>.*`);
  tools are entries within — never per-tool module files.
- **Resources-without-runtime is a defect.** A capability that names a tool
  ships the tool; verify smokes the consumer, not a fingerprint. All
  downloads are pinned declarations; no unpinned downloads, no `sudo`, no
  OS-package-manager installation of managed tools.
- **Foundation inventory (final).** The shell rc lane + fd, fzf, rg,
  lazygit, tree-sitter (checksummed pins) + eza, starship, harlequin+hsql
  (nixpkgs) + tailscale (system legs: `services.tailscale`; standalone-HM
  legs: CLI in `home.packages`, tailscaled a host-owned prerequisite).
  rainfrog retired; the prompt capability dissolved into foundation; op
  lives in secrets; the hsql agent skill provisions at activation,
  version-matched to the harlequin derivation.
- **Verification is behavioral.** VM activation runs, consumer smokes, HM
  idempotency/rollback. Structural assertions (counts, the fold's union
  checks) stay assertions — there are no byte-goldens and no re-record
  rituals.
- **No phase labels.** P0/P1/LM2-style markers are planning scaffolding;
  they live in card bodies, never in landed content.
- **No `workstation/` partition, no `payload/` folder.** The name survives
  only as the flake/product identity.
- **`~/.hermes` stays hot home.** The pinned hermes checkout is runtime
  state (update machinery, the pm store, recovery closures write into it);
  managed skill leaves are read-only store symlinks, and the tools that
  curate skills defer to anything they do not own.

## The retirement ledger

Everything deleted on the road here, and what replaced it:

| Retired | Replacement |
| --- | --- |
| The manifests + the walker + the package format | The co-located capability modules; the report fold walks them (`nix/report.nix`) |
| The resident daemon (`apps/daemon`: EventBus, overlay domains, sessions, listener, wire protocol, the user unit, the socket) | Nothing resident. The switch receipt lands in `~/.local/state/workstation/switch.log`; consumers watch files (the switch log, the theme token path) — nothing polls |
| The Elixir read plane (status/plan/capabilities composition, the baked report) | `nix eval .#workstation.report.<verb>` — the fold evaluated at read time; the shim's read verbs are thin wrappers |
| The `diff` verb's live-probe half | The nix-native tools that own baseline and ownership: `home-manager generations`, `nix store diff-closures` |
| The TUI (the mosaic, apply streaming, the shell) | Nothing — no consumer app, by operator ruling. The bare verb prints usage |
| `apps/`, `mix.exs`, `mix.lock`, `deps/`, `_build/`, `.tool-versions` | Gone; the Elixir plane left the repo (the engine-free gate in `check.sh` holds the line) |
| `nix/engine.nix`, the OTP release, the release tarballs, the locale guard, `tests/direct_boot.sh` | Nothing — there is no runtime artifact to build or stage; distribution is the flake ref (a rev) |
| The theme domain's daemon side | The activation hook + store-path watching: the switch re-points `~/.local/state/workstation/theme.json` at the generation's token store path; consumers read or watch the link |
| `workstation/bin/workstation` (release acquisition, sandbox, anchoring) | `bin/workstation` — the thin dispatch shim, derivation-staged by the home lane |
| The mix test suite, doclint, the shim locale/anchor gates | The static battery (identity, engine-free, shell syntax + ShellCheck, the shim dispatch gate, the nix eval reads) + the docker-nix acceptance + the VM E2E |
| CI's mise/elixir matrix | CI's static job + nix-eval job (evaluation only; closures are the local acceptance's job) |
| `docs/elixir.md`, `docs/lua-migration.md`, `docs/roadmap.md`, `docs/store-design.md` | Git history; `docs/endgame.md` (this file) holds the living shape |
| The pin inventory (`versions.json` at the repo root, read via `builtins.fromJSON`) | The pins declared in their OWNING domain's module (one pin, one owner, one surface): the fetchurl tool pins as version + per-platform url/sha256 literals, the git checkout pins as url + rev in `modules/terminal/terminal.nix` (deployed as `~/.tmux/plugins.pins.json`, the verify lane's anchor); `nix/lib/pins.nix` keeps only the shared HOW. The dead rows retired leak-free: openwiki (pi-era), the neovim bootstrap rows, nunchux's release-asset checksums |

## The endgame decisions

1. **Platform-two (2026-10-22).** The flake targets exactly mac and linux;
   WSL is linux. Every earlier platform carve-out (arch/omarchy, a distro
   leg) is retired with its wiring.
2. **Behavioral verification, no byte-goldens (2026-10-22).** The
   eval-golden byte-guard was two-reader transition scaffolding; post-
   absorption proof is the VM run, the consumer smokes and HM
   idempotency/rollback. Deliberate output changes need no re-record ritual.
3. **Co-located domain modules (2026-10-22).** `modules/<domain>/` holds
   the module and its bytes together; no `workstation/` partition, no
   `payload/` folder, no central catalog. The module tree mirrors the
   capability taxonomy one-to-one.
4. **No engine, no consumer app (2026-10-22, the one-pass ruling).** The
   daemon, the TUI and the Elixir plane retire in one pass — reads become
   `nix eval`, the shim and the switch driver are the whole client. No
   adopt-then-retire transition was built because no host was traversing
   it.
5. **One pin, one owner, one surface (2026-10-26).** The named interim
   closed: `versions.json` retired and its rows moved into the owning
   domains — the fetchurl tool pins as declared module data, the source
   checkouts as the terminal module's url+rev literals (its verify lane
   anchors on the deployed `~/.tmux/plugins.pins.json`, the agent
   domain's deployed-pin law), the hermes runtime staying the one
   flake-input pin (surfaced as `hermesAgentPin`). The change-rule
   survives: a pin bump moves the pin and its consumer together.
