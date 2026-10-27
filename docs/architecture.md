# Workstation architecture

The workstation is a **nixpkgs-native monorepo**: declared state and two
clients. The capability modules under `modules/<domain>/` declare; home
manager renders; `bin/workstation` (reads: thin wrappers over
`nix eval .#workstation.report.<verb>`) are the whole operator surface:
reads are evals, writes are `workstation apply|rollback|update|sync` (the
staged switch driver implements them: leg-native rebuilds plus the
switch.log receipt).

## The final folder structure

| Path | Role |
| --- | --- |
| `flake.nix`, `flake.lock` | The one entry point: inputs framed per domain (each domain owns its pin surface; `follows` dedupes shared nixpkgs/HM), the declared-state report verbs, the host legs, the mesh outputs |
| `modules/<domain>/` | One directory per capability domain — the domain's module file AND the bytes it deploys, co-located: `modules/editor/{editor.nix, nvim/}`, `modules/terminal/{terminal.nix, tmux/, nunchux/}`, `modules/theme/{theme.nix, tokens.nix, tokens.lua}`, `modules/foundation/`, `modules/languages/{node,elixir,typescript,go}/`, `modules/agent/`, `modules/fonts/`, `modules/secrets/`. Adding a capability is adding one directory |
| `nix/` | Shared substrate infrastructure, no capability of its own: `report.nix` (the declared-state fold), `lib/capabilities.nix` (the registry walk), `lib/shell-lane.nix` (the fragment lane's order contract), `lib/license.nix` (the secrets domain's license acceptance), `workstation-switch.nix` (the write plane), `modules/` (the home leg, the system leg, the host-identity options) |
| `hosts/{linux,mac}/` | The two target legs; WSL and any linux server count under the linux leg. `hosts/identity.nix` is the identity template, rewritten per machine by `workstation init` and kept uncommitted |
| `bin/workstation` | The launcher shim: the whole client (POSIX sh). Reads are `nix eval`s over `workstation.report.<verb>`; writes run `workstation apply` (the staged switch driver implements them). The home lane stages the same bytes as a derivation onto the profile PATH |
| `tests/` | The container E2E: `run-container.sh` (the lane), `e2e.nix` (the proof driver), `e2e-home.nix` (the persona) — behavioral acceptance |
| `docs/` | The references; this file is the structure's anchor |
| `.github/` | The static check battery, the CI (static + nix-eval jobs), tagged source archives |

### Flake outputs

`workstation.report` (the read verbs: `status`, `plan`, `capabilities` —
scope with an attrpath), `homeManagerModules.workstation`,
`homeConfigurations` (the linux leg + the e2e container persona),
`darwinConfigurations` (the mac leg), `nixosConfigurations.<host>` (the
linux system plane), `workstationE2E` (the container lane's inputs: the
persona home + the proof driver), `checks.<system>` (`nix flake check` is
the canonical validation entry: the declared-state reads, every host leg's
eval, and the container E2E lane's staged entry), `overlays.default` (pin
overrides only), `workstationTheme.lib`, `hermesSkills`, `hermesAgentPin`.

## The invariants

- **Two targets.** mac and linux; WSL is linux. No distro-named legs, no
  arch/omarchy references anywhere.
- **Identity is captured once per machine, at install time.**
  `workstation init` writes `hosts/identity.nix` (hostname, user, home)
  and the local rewrite stays uncommitted — the repo is a template
  carrying no personal strings at HEAD; evals read the dirty working
  tree. MagicDNS derives the host's tailscale name from the hostname.
  The identity gate in `check.sh` reds on personal strings anywhere in
  the tracked tree.
- **The filesystem is the capability registry.** No central catalog: the
  walk (`nix/lib/capabilities.nix`) discovers `modules/<domain>/`, and
  the report fold evaluates each capability once against home-manager.
  Options are domain-level (`workstation.<domain>.*`); tools are entries
  within — never per-tool module files.
- **Resources-without-runtime is a defect.** A capability that names a
  tool ships the tool; verify smokes the consumer, not a fingerprint.
  Tools ride nixpkgs (the overlay + floors keep the eval loud); the
  remaining pins (herdr, the tmux/nunchux checkouts, the hermes checkout
  input) are pinned declarations. No unpinned downloads, no `sudo`, no
  OS-package-manager installation of managed tools.
- **Foundation inventory.** The shell rc lane (the fragments' declared
  order slots) + fd, fzf, rg, lazygit, tree-sitter, node, pnpm, go, op,
  btop, the JetBrainsMono Nerd Font (nixpkgs via the foundation input,
  floored in the owning modules) + eza, starship, harlequin+hsql
  (nixpkgs) + the tailscale transport (system legs: `services.tailscale`;
  standalone-HM legs: CLI in `home.packages`, tailscaled a host-owned
  prerequisite). nvm retired — nix owns the node runtime.
- **Verification is behavioral.** Container activation runs, consumer
  smokes, HM idempotency/rollback. Structural assertions (counts, the
  fold's union checks) stay assertions — no byte-goldens, no re-record
  rituals.
- **No phase labels.** Planning markers live in card bodies, never in
  landed content.
- **No `workstation/` partition, no `payload/` folder.** The name survives
  only as the flake/product identity.
- **`~/.hermes` stays hot home.** The pinned hermes checkout is runtime
  state (update machinery, the pm store, recovery closures write into it);
  managed skill leaves are read-only store symlinks, and the tools that
  curate skills defer to anything they do not own.

## The declared state and the read verbs

The report carries the declared surface structurally: counts, the target
lists (file targets and tree claims), the capability order, the fragment
lane (per-target, in the capabilities' declared order), and the
per-capability accounting rows (id, foundation, the declared surfaces, the
retire tombstones). The fold's integrity assertions run at eval time — a
misclassified module file, a fragment lane that does not compose, or an
absolute (identity-carrying) target fails the evaluation; nothing serves.

The flake projects the report as the read verbs (the operator-facing
contract):

- `status` — the declared inventory: counts + capability order.
- `plan` — the surface the next switch applies (file targets, tree
  claims, the fragment lane, the retire list) with the report digest —
  the declared state's content id. Mutation is never a read's job:
  the write plane owns it (atomic generations, rollback, the receipt).
- `capabilities` — the accounting keyed by capability id; attrpath
  scoping is free (`nix eval .#workstation.report.capabilities.editor`).

Ownership and baseline over time are the nix generation's story
(`nix store diff-closures` / `home-manager generations`).

## The capability-module law

A capability is self-contained at its final address: `modules/<domain>/`
holds the capability's home-manager module(s) beside the payload bytes it
deploys. The filesystem is the registry: the capability walk
(nix/lib/capabilities.nix) is the one discovery both the home leg's
imports and the report's fold read; a hand-kept module list is a defect by
definition. Adding a capability is adding one directory. Options are
domain-level (`workstation.<domain>.*`); tools are entries within; per-tool
module files are never created.

## The client law

`bin/workstation` stays plain POSIX sh: resolve the flake (`--flake` >
`$WORKSTATION_FLAKE` > the enclosing checkout > the staged generation
snapshot), dispatch the verb, exec. Reads exec `nix eval --json` over the
report attrs and print the answer unchanged; writes exec the staged
`workstation apply` (the staged driver); help exits 0, usage errors exit 2, a read with no
resolvable flake fails closed naming the fix. The shim dispatch gate
(.github/scripts/shim-dispatch.sh) holds this contract in CI with a stub
nix.

## Enforcement

The check battery (.github/scripts/check.sh) holds the lines in code: the
identity gate (personal strings only in the machine-local
`hosts/identity.nix`), the tree-purity gate (the tree-wide grep for a
foreign module-system token stays empty), shell syntax + ShellCheck, the
shim dispatch gate, the nix eval read gate. Verification beyond the
battery is behavioral — the docker-nix closure acceptance and the
container E2E (docs/testing.md).
