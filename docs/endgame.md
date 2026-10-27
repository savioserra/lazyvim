# The endgame: the repo's final shape

The workstation is a **nixpkgs-native monorepo**. The capability modules
declare; home-manager renders; two small shell clients (the launcher shim
and the switch driver) are the whole operator surface; `nix eval` answers
every question about the declared state. This document is the structure's
home.

## The final folder structure

| Path | Role |
| --- | --- |
| `flake.nix`, `flake.lock` | The one entry point: inputs framed per domain (each domain owns its pin surface; `follows` dedupes shared nixpkgs/HM), the declared-state report verbs, the host legs, the mesh outputs |
| `modules/<domain>/` | One directory per capability domain — the domain's module file AND the bytes it deploys, co-located: `modules/editor/{editor.nix, nvim/}`, `modules/terminal/{terminal.nix, tmux/, nunchux/}`, `modules/theme/{theme.nix, tokens.nix, tokens.lua}`, `modules/foundation/`, `modules/languages/{node,elixir,typescript,go}/`, `modules/agent/`, `modules/fonts/`, `modules/secrets/`. Adding a capability is adding one directory |
| `nix/` | Shared substrate infrastructure, no capability of its own: `report.nix` (the declared-state fold), `lib/capabilities.nix` (the registry walk), `lib/shell-lane.nix` (the fragment lane's order contract), `lib/license.nix` (the secrets domain's license acceptance), `workstation-switch.nix` (the write plane), `modules/` (the home leg, the system leg, the host-identity options) |
| `hosts/{linux,mac}/` | The two target legs WSL and any linux server count under the linux leg. `hosts/<host>/default.nix` is the ONLY place a host's identity is written |
| `bin/workstation` | The launcher shim: the whole client (POSIX sh). Reads are `nix eval`s over `workstation.report.<verb>`; writes delegate to the staged `workstation-switch`. The home lane stages the same bytes as a derivation onto the profile PATH |
| `tests/` | `tests/nix/` (the container E2E: `run-container.sh` the lane, `e2e.nix` the proof driver, `e2e-home.nix` the persona) — behavioral acceptance |
| `docs/` | The references; this file is the structure's anchor |
| `.github/` | The static check battery, the CI (static + nix-eval jobs), tagged source archives |

### Flake outputs (locked)

`workstation.report` (the read verbs: `status`, `plan`, `capabilities` —
scope with an attrpath), `homeManagerModules.workstation`,
`homeConfigurations` (the linux leg + the e2e@container persona),
`darwinConfigurations` (the mac leg), `nixosConfigurations.<host>` (the linux system plane),
`workstationE2E` (the container lane's inputs: the persona home + the proof
driver), `checks.<system>` (`nix flake check` is the
canonical validation entry: the declared-state reads, every host leg's
eval, and the container E2E lane's staged entry), `overlays.default` (pin overrides ONLY),
`workstationTheme.lib`, `hermesSkills`, `hermesAgentPin`.

## The invariants

- **Two targets.** mac and linux; WSL is linux. No distro-named legs, no
  arch/omarchy references anywhere.
- **Identity is captured once per machine, at install time.**
  `workstation init` writes `hosts/identity.nix` (hostname, user, home,
  tailscale fqdn) and the local rewrite stays uncommitted — the repo is
  a template carrying no personal strings at HEAD; evals read the dirty
  working tree. tailscale, the dashboard binding and the flake's rebuild
  keys derive from it. The identity gate in `check.sh` reds on personal
  strings anywhere in the tracked tree.
- **The filesystem is the capability registry.** No central catalog, no
  manifests: the walk (`nix/lib/capabilities.nix`) discovers
  `modules/<domain>/`, and the report fold evaluates each capability once
  against home-manager. Options are domain-level (`workstation.<domain>.*`);
  tools are entries within — never per-tool module files.
- **Resources-without-runtime is a defect.** A capability that names a tool
  ships the tool; verify smokes the consumer, not a fingerprint. Tools ride
  nixpkgs (the pins machinery retired 2026-10-27 — the overlay + floors
  keep the eval loud); the remaining pins (herdr, the tmux/nunchux
  checkouts, the hermes checkout input) are pinned declarations. No
  unpinned downloads, no `sudo`, no OS-package-manager installation of
  managed tools.
- **Foundation inventory (final).** The shell rc lane (the fragments'
  declared order slots) + fd, fzf, rg, lazygit, tree-sitter, node, pnpm,
  go, op, the JetBrainsMono Nerd Font (nixpkgs via the foundation input,
  floored in the owning modules) + eza, starship, harlequin+hsql (nixpkgs)
  + tailscale (system legs: `services.tailscale`; standalone-HM
  legs: CLI in `home.packages`, tailscaled a host-owned prerequisite).
  rainfrog retired; the prompt capability dissolved into foundation; op
  lives in secrets; the hsql agent skill provisions at activation,
  version-matched to the harlequin derivation; nvm retired with the pins
  machinery — nix owns the node runtime.
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
