# Workstation architecture

The engine is a **read plane over the declared state**. The declared state
is the capability modules' report — `flake.evalReport`, the fold over
`modules/<domain>/` (nix/report.nix) — baked into the engine's release by
`nix/engine.nix`, so release and declared state ship from one flake
snapshot and the reads are coherent by construction. The engine knows what
a capability is — never which capabilities exist; the report is the only
declared-state source, and reads fail closed without it.

## Layers and the law of each

1. **Kernel — `Workstation.Core`** — generic machinery: the report reader
   (`Report`), engine state and the guarded home reads (`EngineState`), the
   theme token/role/appearance platform (`Theme.*`), canonical JSON and the
   content digest. Speaks only shapes. Forbidden: the name of any consumer.
2. **Daemon — `Workstation.Daemon`** — the wire surface: reads
   (`status.run` / `plan.run`, assembled once in `Daemon.Read`), pubsub
   (the overlay domains), the `system` domain's generation receipts, the
   theme resolver, sessions/shutdown. The daemon is the one place that
   composes the wires; the CLI renders them unchanged.
3. **CLI/TUI — `Workstation.CLI`** — the thin client: verb dispatch, the
   ensure-daemon transport, plain-text/TUI rendering, the grouped
   capabilities view (a pure fold over the two read wires).

Dependency direction: cli → daemon → kernel. Never sideways by name, never
downward.

(The contracts, backends and package layers retired with the manifest
format — docs/absorption.md carries the death certificate. The theme
platform is the one pre-absorption engine that survives intact.)

## The declared state and the read verbs

The report carries the declared surface structurally: counts, the target
lists (file targets and tree claims), the capability order, the fragment
lane (per-target, in the capabilities' merged declaration order), and the
per-capability accounting rows (id, foundation, the declared surfaces, the
retire tombstones). The fold's integrity assertions are the nix side; the
reader's structural validation is this side — a report either validates or
nothing is served.

  * `status` — the declared inventory: the engine block, the resolved
    destination, the platform, counts, capability order, accounting rows
    (`workstation.status.v2`).
  * `plan` — the report digest as the generation id, the declared surface,
    and the probed live state of every declared target (lstat no-follow,
    `absent` / `link -> dest` / `type mode-octal`) — the declared-vs-live
    review surface (`workstation.plan.v2`). The plan never mutates: the
    nix substrate's `workstation-switch` drivers own mutation (atomic
    generations, rollback, publish).

Ownership and baseline are the nix generation's story
(`nix store diff-closures` / `home-manager generations`). (The recorded
plan bodies and their golden matrix retired with the format they pinned —
docs/absorption.md decision 5: verification is behavioral, plus the fold's
eval-time assertions.)

## The capability-module law

A capability is self-contained at its final address: `modules/<domain>/`
holds the capability's home-manager module(s) beside the payload bytes it
deploys (the payload rename is the absorption chain's last card — until it
lands, the bytes live under `workstation/packages/`). The filesystem is
the registry: the capability walk (nix/lib/capabilities.nix) is the one
discovery both the home leg's imports and the report's fold read; a
hand-kept module list is a defect by definition. Adding a capability is
adding one directory.

## Enforcement

A layer-law guard suite fails CI when forbidden vocabulary reappears (the
kernel naming a consumer, the theme platform naming a consumer) and when
import direction inverts. The rules are enforced in code, not prose.

## Module hierarchy & moduledoc conventions

The module tree mirrors the layers, and every module's moduledoc is the
architecture's documentation surface:

1. **Kernel — `Workstation.Core`** (report, engine_state, theme, json/
   canonical_json, digest): pure machinery. Each kernel moduledoc states
   the kernel law: it names no consumer — it speaks only shapes.
2. **Daemon — `Workstation.Daemon.*`**: the wire surfaces. A capability
   moduledoc names the ops it owns and the domain it publishes.
3. **CLI — `Workstation.CLI.*`**: the front end (router, render, the TUI
   shell). View modules state their wire inputs and stay terminal-free
   where output must survive redirection.

The layer-law guard suite (`ArchitectureDepsTest`, `LayerLawTest`)
enforces the namespaces and the forbidden vocabulary in code; a moduledoc
that contradicts this section fails the suite the same way a violated
import does.

## Current state and debt

The engine is the report reader now. Known debt: the release bake rides
the engine derivation (nix/engine.nix), and per-target NIF artifacts for
the darwin leg remain the named build gap. The retired increments — the
manifest walker, the catalog arm, the graph, the contracts, the chezmoi
backend, the plan composer — are history, not debt: docs/absorption.md is
the record.
