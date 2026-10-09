# Workstation roadmap

Each run is a swarm: tasks are agent-session-sized (one actor, 60–120 min,
atomic commits, evidence report, `done-and-landed` or `named-FAIL`), gated by
the registry's dependency DAG, and closed by a full-battery gate task. Runs
are seeded into the registry only when their predecessor's gate passes; this
document is the contract they execute against.

Actors: `core` (elixir engine + goldens), `tree` (workstation tree, docs,
verify), `gate` (verification only).

## R1 — Purification (in flight)

| task | owner | depends on | scope / exit |
|---|---|---|---|
| salvage | core | — | full suite on the WIP; three convictions as atomic commits (theme purge / provider contract + nvim compositor / source_name → chezmoi backend) |
| guards | core | salvage | layer-law ExUnit suite + planted-violation self-test + exemption review (policy pins, golden fixture ids, bootstrap mention) |
| download | core | salvage | download contract + backend: pinned url+version+sha256+target, idempotent, fail-closed; tests + goldens |
| folders | tree | salvage | workstation/packages regrouped on the domain axis, history-preserving, every consumer updated |
| payloads | tree | folders | pi-fabric replaces pi-subagents; billion-context replaces billion-context-pi with canonical install verify |
| hierarchy | core | guards, download | namespaces mirror layers: contracts own namespace, backends leave Core, packages become Workstation.Packages.*; moduledoc conventions into docs/architecture.md |
| gate | gate | all | full battery, push, SWARM R1: DONE |

## R2 — First consumer proof: nunchux

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r2.git-contract | core | R1 gate | `Packages.git`: pinned-clone recipe kind (url + commit pin, shallow-safe, idempotent pin verify), plan/apply/journal integration, tests + goldens |
| r2.nunchux-package | tree | R1 gate | nunchux as a package: manifest, config, root C-Space chord, verify script; binary via the download contract (pinned 3.1.3 linux-x86_64 + sha256 from versions.json; pre-seed so upstream's ensure_binary never fetches) |
| r2.nunchux-wiring | tree | r2.git-contract, r2.nunchux-package | declare the TPM clone as a git recipe in the nunchux manifest; delete the manual-provisioning contract note from docs/tmux.md |
| r2.gate | gate | r2.nunchux-wiring | battery + authorized host apply + chord verified live on the real host; SWARM R2: DONE |

Exit: the launcher is provisioned entirely by declared recipes — "declare,
don't hand-place" proven end-to-end.

## R3 — Platform hardening

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r3.profile-contract | core | R1 gate | profile platform contract extracted (nvim's compositor becomes its package-owned implementation; the seam helix/zed would implement) |
| r3.shell-contract | core | R1 gate | shell fragments as a contract platform over the existing compositor |
| r3.theme-derivation | core | R1 gate | derivation contract formalized: packages declare needs/metadata, derive from theme roles via consumer-owned adapters (tmux/pi/herdr patterns documented as the canon) |
| r3.selfserve-proof | core | r3.profile-contract, r3.shell-contract, r3.theme-derivation | synthetic test package achieves full self-serve — manifest + payloads only, zero engine edits |
| r3.doclint | tree | R1 gate | moduledoc convention linter in CI (every module states layer + one-law; contracts name implementor policy) |
| r3.gate | gate | r3.selfserve-proof, r3.doclint | battery + push; SWARM R3: DONE |

Exit: a new editor/terminal/agent package is a manifest and payloads.

## R4 — The package store (research-first)

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r4.research | main | R3 gate | registry-design research (npm/cargo/hex index shapes, signing, sparse index, mirrors) → store design proposal to the user BEFORE implementation |
| r4.lockfile | core | r4.research approved | host lockfile: resolve to exact versions + hashes, verify on apply, drift fails closed |
| r4.store-schema | core | r4.research approved | store manifest schema + validation (name, version, deps, compat, checksums, artifact URLs) |
| r4.store-index | core | r4.store-schema | local-first sparse index format + deterministic resolution over it |
| r4.store-artifacts | core | r4.store-schema | content-addressed artifact fetch + integrity verify + local cache |
| r4.install | core | r4.lockfile, r4.store-index, r4.store-artifacts | end-to-end: install a package from a local store fixture into a sandbox home, hash-verified |
| r4.mirror | core | r4.install | mirror config + offline vendoring path |
| r4.publish | core | r4.install | author-side pack/ship: package dir → store entry + artifact + checksums |
| r4.gate | gate | r4.mirror, r4.publish | battery + push; SWARM R4: DONE |

Exit: install from the store into a sandbox home, verified, reproducible from
the lockfile.

## R5 — Fresh-box parity

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r5.bootstrap-store | core | R4 gate | bootstrap consumes store + lockfile (engine release, runtime payloads, packages) |
| r5.parity-proof | gate | r5.bootstrap-store | clean sandbox home → full apply from store → byte-identical to this host's managed state |
| r5.runbook | tree | r5.bootstrap-store | fresh-box runbook in docs |
| r5.gate | gate | r5.parity-proof, r5.runbook | SWARM R5: DONE |

Exit: a new machine reaches this host's state from nothing but the store,
the lockfile, and the engine release — the strangler gap closed for good.

## Conventions across runs

- Swarm sizing scales at seed time to the DAG's fork width, within the
  file-ownership partition — never two writers on one partition. Planned
  scale-ups: R3 seeds `core2` (profile vs shell vs theme-derivation run as
  namespace-disjoint parallel lanes) and R4 may add a second core actor for
  mirror/publish; R1/R2 stay two-lane. Trigger, not vanity: an actor is added
  only when mutually independent, partition-disjoint tasks would otherwise
  serialize behind one owner.

- Lessons land as `chore(memory)` commits per run (gate task owns it).
- Every task reports to `/tmp/fleet/reports/swarm-<run>-<task>.md`.
- Behavior-conservation rule holds everywhere except the increment's declared
  surface: goldens byte-identical unless the task says otherwise.
- [Autonomy grant, 2026-10-09 session] The user pre-approved the full
  chain: runs seed automatically as their predecessor's gate passes — no
  per-run approval. R4's research step produces a documented design decision
  (stored in the repo) and proceeds; it does not wait on approval. The
  roadmap may be amended between runs, never silently inside one.
