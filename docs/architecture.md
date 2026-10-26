# Workstation architecture

The substrate is **declared state and two clients**. The declared state is
the capability modules under `modules/<domain>/` — co-located module and
payload bytes — rendered by home-manager and reported by the fold
(`nix/report.nix`). The clients are `bin/workstation` (reads: thin
wrappers over `nix eval .#workstation.report.<verb>`; help/usage) and
`workstation-switch` (the write plane: leg-native rebuilds plus the
switch.log receipt). There is no resident process anywhere: the daemon,
the wire protocol and the TUI retired with the Elixir plane
(docs/endgame.md carries the ledger; docs/absorption.md the earlier
deaths).

## The declared state and the read verbs

The report carries the declared surface structurally: counts, the target
lists (file targets and tree claims), the capability order, the fragment
lane (per-target, in the capabilities' merged declaration order), and the
per-capability accounting rows (id, foundation, the declared surfaces, the
retire tombstones). The fold's integrity assertions run at eval time — a
misclassified module file, a fragment lane that does not compose, or an
absolute (identity-carrying) target fails the evaluation; nothing serves.

The flake projects the report as the read verbs (the operator-facing
contract — reshaped freely from the retired wire schemas; no
byte-compatibility is owed):

  * `status` — the declared inventory: counts + capability order.
  * `plan` — the surface the next switch applies (file targets, tree
    claims, the fragment lane, the retire list) with the report digest —
    the declared state's content id. Mutation is never a read's job:
    `workstation-switch` owns it (atomic generations, rollback, the
    receipt).
  * `capabilities` — the accounting keyed by capability id; attrpath
    scoping is free (`nix eval .#workstation.report.capabilities.editor`).

Ownership and baseline over time are the nix generation's story
(`nix store diff-closures` / `home-manager generations`) — the retired
plan verb's live-probe half is deliberately not re-created.

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
`workstation-switch`; help exits 0, usage errors exit 2, a read with no
resolvable flake fails closed naming the fix. The shim dispatch gate
(.github/scripts/shim-dispatch.sh) holds this contract in CI with a stub
nix.

## Enforcement

The check battery (.github/scripts/check.sh) holds the lines in code: the
identity gate (personal strings only in `hosts/<host>/default.nix`), the
engine-free gate (the tree-wide grep for the Elixir module token stays
empty), shell syntax + ShellCheck, the shim dispatch gate, the nix eval
read gate. Verification beyond the battery is behavioral — the docker-nix
closure acceptance and the VM E2E (docs/testing.md).

## Current state and debt

The substrate is the endgame shape (docs/endgame.md). Named remaining
work: none — the last named item, the pin inventory (`versions.json`)
relocating into the owning domains' module and flake-input surfaces,
landed 2026-10-26 (one pin, one owner, one surface). The retired
increments — the manifests, the walker, the format, the write/acquisition
plane, the daemon, the wire protocol, the TUI, the Elixir plane, the pin
inventory — are history, not debt: docs/absorption.md is the record, Git
the archive.
