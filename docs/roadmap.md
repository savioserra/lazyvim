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

Backlog input: the sage's independent review (`/root/fleet/design/elixir-review.md`,
HEAD a6eb9e4b) found zero P0s; its 9 P1 idiom debts are R3 work items — top:
the triplicated discovery machinery (Catalog.Discover / Source.Provider.Discover /
Contract discovery consolidate to one helper), `source.ex`'s residual hardcoded
provider set + god-module split along pipeline stages, `catalog.ex` provider-string
cond dispatch, dead fold accumulators. P2 polish burns opportunistically.

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r3.profile-contract | core | R1 gate | profile platform contract extracted (nvim's compositor becomes its package-owned implementation; the seam helix/zed would implement) |
| r3.shell-contract | core | R1 gate | shell fragments as a contract platform over the existing compositor |
| r3.theme-derivation | core | R1 gate | derivation contract formalized: packages declare needs/metadata, derive from theme roles via consumer-owned adapters (tmux/pi/herdr patterns documented as the canon) |
| r3.selfserve-proof | core | r3.profile-contract, r3.shell-contract, r3.theme-derivation | synthetic test package achieves full self-serve — manifest + payloads only, zero engine edits |
| r3.doclint | tree | R1 gate | moduledoc convention linter in CI (every module states layer + one-law; contracts name implementor policy) |
| r3.gate | gate | r3.selfserve-proof, r3.doclint | battery + push; SWARM R3: DONE |

Exit: a new editor/terminal/agent package is a manifest and payloads.

## R4 — Package self-containment, then the release

User ruling (2026-10-09 session, verbatim intent): packages must be
self-contained and live OUTSIDE the kernel; maintaining a package in two
places is unacceptable; the store mechanism is NOT needed; this refactor
lands BEFORE the v2.0.0 release. It supersedes the store design
(store-design.md retained as retired history). Discovery stays the only
engine-to-package path: the engine finds packages, it never embeds or
mirrors them — the law lives in docs/architecture.md ("Package
self-containment").

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r4.selfcontain-move | core | R3 gate | every package leaves the kernel namespace for its own self-contained tree — manifest, payloads, profiles, derivation logic in exactly one place; kernel-side copies and templates deleted, discovery is the sole path; guard tables move with the code |
| r4.dual-home-ban | core | r4.selfcontain-move | a guard fails the build when any package fact has two homes (an engine-side copy of package content); ArchitectureDepsTest/LayerLawTest tables updated |
| r4.release-v2 | gate | r4.selfcontain-move | v2.0.0 cut from the self-contained tree — version bump, changelog, battery green on the new layout |
| r4.gate | gate | r4.dual-home-ban, r4.release-v2 | battery + push; SWARM R4: DONE |

Exit: a package is one tree the engine discovers — never a kernel copy —
and v2.0.0 ships from it.

## R5 — Fresh-box parity

| task | owner | depends on | scope / exit |
|---|---|---|---|
| r5.bootstrap-tree | core | R4 gate | ✅ bootstrap consumes the package tree (engine release + self-contained packages) — no store, no lockfile |
| r5.parity-proof | gate | r5.bootstrap-tree | ✅ clean sandbox home → full apply from the package tree → byte-identical to this host's managed state (gen 7df6e5e5 from tree ba878f67; every delta decomposed) |
| r5.runbook | tree | r5.bootstrap-tree | ✅ fresh-box runbook in docs |
| r5.gate | gate | r5.parity-proof, r5.runbook | ✅ SWARM R5: DONE (2026-10-15) |

Sprint 7 status (2026-10-15 closing gate): **R5 DONE — fresh-box parity
proven on both legs.** **Parity-proof (t_fa2e57ba)**: managed host and a
fresh sandbox container (stock ubuntu:24.04) both applied generation
`7df6e5e5` from tree `ba878f67` (== origin/main) — generation source trees
byte-identical (`diff -r` clean), journals identical (71/71 targets, 66/71
records byte-equal), and all live managed state re-verified against records
on both sides: 38 files + 13 links byte-identical, 7 clones at identical
commits, 12/12 archive pins equal with extracted trees content-matched.
Every delta decomposed (PROOF.md): RC files differ only in user-owned base +
fragment accumulation order; the rest is host runtime state outside the
apply surface (reconciled per t_41c36f22). **Bare-box leg (t_a99c1216,
operator-authorized container-equivalent, dashboard 2026-10-15 22:19)**: two
fresh stock ubuntu:24.04 boxes ran the verbatim README one-liner from tree
`889ee65e` (== origin/main at run time) — with the runbook's stated prereqs
the apply fails closed naming the missing tool (`xz`, INSTALL_EXIT=4;
measured prereq set: git+curl+ca-certificates+xz-utils+unzip), and with the
corrected set the whole chain goes green from nothing (INSTALL_EXIT=0,
generation `fa75498a`, verify 14 packages; stop-rule refusal on a second
run; drift detection + re-convergence proven on-box). Carded follow-ups,
none blocking the exit criterion: t_3ce571c5 (prereq docs truth-fix — apply
needs xz-utils+unzip beyond git+curl), t_7b9a45e7 (piped `curl | sh` masks
fetch failure as exit 0), t_d9806820 (zombie-as-alive daemon-stop guard;
engine side landed in 3d74c489), t_3b3298aa (latin1 locale guard). What the
2026-10-14 gate proved still holds: bootstrap-tree (a9254aa2) and the
runbook landed, and the aurora rehearsal converged a lived-in host from the
package tree (gen 8a371a55) — full history in the docs(roadmap) commit log.

Exit: a new machine reaches this host's state from nothing but the engine
release and the package tree — the strangler gap closed for good.

## Conventions across runs

- Registry literals: finished tasks use status exactly `completed` (narrative
  goes in the result field). The unblocker cascades on dep-status events only —
  a task seeded after its dependencies are already terminal must be touched
  (one resolver pass: re-put as `ready`) or it freezes. Workers claim `ready`,
  never prose statuses.

- Swarm sizing scales at seed time to the DAG's fork width, within the
  file-ownership partition — never two writers on one partition. Planned
  scale-ups: R3 seeds `core2` (profile vs shell vs theme-derivation run as
  namespace-disjoint parallel lanes) and R4 may add a second core actor for
  the package-tree move; R1/R2 stay two-lane. Trigger, not vanity: an actor is added
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
