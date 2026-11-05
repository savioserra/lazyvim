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
| `flake.nix`, `flake.lock` | The entry point: one nixpkgs input, home-manager, nix-darwin, NixOS-WSL; the machine's legs, the report verbs, the checks |
| `modules/<domain>/` | One directory per capability domain: the module (options + declarations) and the bytes it deploys. `modules/default.nix` lists the modules |
| `nix/` | Shared infrastructure: `report.nix` (the read verbs), `lib/machine.nix` (the machine file), `lib/license.nix` (the unfree acceptance), `workstation-switch.nix` (the write plane), `modules/` (the home plane, the system plane, the host options) |
| `hosts/` | `linux/` and `mac/` (the system legs), `machine.json` (identity + settings) and `peers.nix` (A2A peers): templates rewritten per machine by `workstation init` / `add|remove` / `fleet` / `peers`, kept uncommitted |
| `bin/workstation` | The launcher (POSIX sh): reads are `nix eval`s over `workstation.report.<verb>`; `add|remove|fleet` edit `hosts/machine.json` (jq); `peers` runs `workstation-peers` on `hosts/peers.nix`; writes exec the staged switch driver |
| `tests/` | The container E2E: `run-container.sh`, `e2e.nix` (the driver), `e2e-home.nix` (the persona), `e2e-selections*.nix` (its flag modules) |
| `docs/` | The references; this file is the structure's anchor |
| `.github/` | The static check battery, the CI (static + nix-eval jobs), tagged source archives |

### Flake outputs

`workstation.report` (the read verbs: `status`, `plan` — with the
machine's selection pins —, `capabilities` — scope with an attrpath,
`selectable`, `selections`), `homeManagerModules.workstation`,
`homeConfigurations` (the linux leg + the e2e container persona),
`darwinConfigurations` (the mac leg), `nixosConfigurations.<host>` (the
linux system plane), `workstationE2E` (the container lane's inputs: the
persona home + the proof driver), `checks.<system>` (`nix flake check` is
the canonical validation entry: the declared-state reads, every host leg's
eval, and the container E2E lane's staged entry) and `workstationTheme.lib`.

## The invariants

- **Two targets.** mac and linux; WSL is linux.
- **The machine is captured once, at install time.** `workstation init`
  writes `hosts/machine.json` (host, user, home, system); the local rewrite
  stays uncommitted and the identity gate reds on personal strings in the
  tracked tree.
- **Flags are options.** `settings` in the machine file is a home-manager
  option tree; each domain declares `workstation.<domain>.enable` (members
  `workstation.<domain>.<member>.enable`) and gates itself; the module
  system validates every flag.
- **Domains own their options.** A domain contributes to another only
  through an option the other declares, guarded by its enable; no path
  imports across domains.
- **Resources-without-runtime is a defect.** A capability that names a
  tool ships the tool; verify smokes the consumer, not a fingerprint.
  Tools ride the one nixpkgs input; the
  remaining pins (herdr, the tmux/nunchux checkouts, the hermes checkout
  input) are pinned declarations. No unpinned downloads, no `sudo`, no
  OS-package-manager installation of managed tools.
- **Foundation inventory.** bash and zsh through home-manager's
  `programs.*` modules + fd, fzf, rg, lazygit, tree-sitter, node, pnpm, go, op,
  btop, the JetBrainsMono Nerd Font + eza, starship, harlequin+hsql
  (nixpkgs) + the tailscale transport (system legs: `services.tailscale`;
  standalone-HM linux legs: the CLI in `home.packages`, tailscaled the
  substrate's own systemd unit; another tailscale install stops the apply,
  named).
- **Verification is behavioral.** Container activation runs, consumer
  smokes, HM idempotency/rollback. Structural assertions (counts, the
  fold's union checks) stay assertions — no byte-goldens, no re-record
  rituals.
- **No `workstation/` partition, no `payload/` folder.** The name survives
  only as the flake/product identity.
- **`~/.hermes` stays hot home.** The pinned hermes checkout is runtime
  state (update machinery, the pm store, recovery closures write into it);
  managed skill leaves are read-only store symlinks, and the tools that
  curate skills defer to anything they do not own.

## The declared state and the read verbs

The report reads one evaluation of the machine's home plane: each
declaration is attributed to the capability whose module defines it
(`definitionsWithLocations`). It carries counts, the capability order,
the target lists (file targets and tree claims), the upstream
`programs.*` each capability enables, and per-capability rows.

The flake projects the report as the read verbs (the operator-facing
contract):

- `status` — the declared inventory: counts + capability order.
- `plan` — the surface the next switch applies (file targets, tree
  claims, the enabled programs, the flag pins) with the report digest —
  the declared state's content id. Mutation is never a read's job:
  the write plane owns it (atomic generations, rollback, the receipt).
- `capabilities` — the accounting keyed by capability id; attrpath
  scoping is free (`nix eval .#workstation.report.capabilities.editor`).

Ownership and baseline over time are the nix generation's story
(`nix store diff-closures` / `home-manager generations`).

## The capability-module law

A capability is self-contained at `modules/<domain>/`: its options, its
declarations and its payload bytes. `modules/default.nix` lists the
modules; every leg imports all of them and each gates on its own enable.
Tools come from the one nixpkgs input.

## The client law

`bin/workstation` stays plain POSIX sh: resolve the checkout (`--flake` >
`$WORKSTATION_FLAKE` > the enclosing checkout > `$WORKSTATION_CHECKOUT`,
recorded by init), build its committed `HEAD` (`git+file://…?rev=`) with
`--override-input machine-files path:<checkout>/hosts`, dispatch the verb,
exec. Reads exec `nix eval --json` over the
report attrs and print the answer unchanged; writes exec the staged
`workstation apply` (the staged driver); help exits 0, usage errors exit 2, a read with no
resolvable flake fails closed naming the fix. The shim dispatch gate
(.github/scripts/shim-dispatch.sh) holds this contract in CI with a stub
nix.

## Enforcement

The check battery (.github/scripts/check.sh) holds the lines in code: the
identity gate (personal strings only in the machine-local
`hosts/machine.json`), the tree-purity gate (the tree-wide grep for a
foreign module-system token stays empty), shell syntax + ShellCheck, the
shim dispatch gate, the nix eval read gate. Verification beyond the
battery is behavioral — the docker-nix closure acceptance and the
container E2E (docs/testing.md).
