# Workstation architecture

The engine is a **capability-speaking microkernel**. It knows what a capability
is — never which capabilities exist. Packages are self-describing carriers that
add capabilities to the host; a registry discovers them; the kernel resolves
and applies them. Dependencies between packages are declared, versioned, and
capability-keyed — never direct references.

## Layers and the law of each

1. **Kernel** — generic machinery: manifest discovery, dependency resolution,
   plan composition, the declared-effects view. Speaks only
   contracts and shapes. Forbidden: the name of any package, backend, or
   consumer. The kernel cannot answer "is nvim installed"; it can answer "is
   the capability provided by package X satisfied".
2. **Contracts (ports)** — the technology-neutral capability surfaces:
   a thing that wants colors (theme), a thing that owns files (source), a
   thing that fetches pinned artifacts (download), a thing that provisions
   mise-managed tools (mise), a thing that composes
   shell state, a thing with profiles. Contracts define the handshake, never
   an implementation.
3. **Backends (adapters)** — one dialect per backend behind a contract
   (e.g. the chezmoi file-source dialect and its native name encoding).
   Only the backend layer may speak its dialect; nothing above or beside
   imports it by name.
4. **Platform engines** — generic domain engines over contracts (the theme
   token/role/appearance engine). Forbidden: any consumer's name. Consumers
   derive from the platform; the platform never learns who consumes it.
5. **Packages** — where everything concrete lives: files, settings, profiles,
   colorscheme derivations, binary pins, version pins. A package declares a
   manifest (identity, domain, version, capabilities provided, capabilities
   consumed, compatibility) and owns its derivation logic contract-calling.
   A package is a self-contained tree outside the kernel — one home per
   package; the engine discovers it, never embeds or mirrors it.

Dependency direction: packages → contracts → kernel, with backends plugging
into contracts. Never sideways by name, never downward.

## Discovery and resolution

The registry composes the catalog from whatever manifests the package tree
carries — data (`manifest.json`) or, while the data conversion runs,
compiled manifest modules — never a hand-written registration list.
Discovery is deterministic (sorted, test-excluded, conformance-validated,
duplicate-id-rejecting). Resolution builds an acyclic graph over declared
provides/requires: orders dependents after dependencies, fails loudly on
missing requirements, incompatible versions, cycles, or contested
capabilities. Optional requires degrade gracefully instead of failing.

Adding a package — or swapping one (editor, terminal, agent runtime) — is
adding a manifest plus payloads. Zero kernel edits. An unknown package
self-serves every platform through contracts alone.

## The pipeline (the engine's one stage list)

The engine is ONE named stage list reduced over a `%Workstation.Pipeline.Run{}`
accumulator (`Workstation.Pipeline`):

    discover -> resolve -> compose

Kernel modules implement stages — catalog discovery, dependency resolution,
plan composition — and nothing else threads evaluation state by
parameter. The pipeline is the READ fold: the plan's declared mutation
program (`Workstation.Pipeline.effects/1`: per-target effects first, the
single generation-apply effect last) is collected from DISCOVERED
`Workstation.Core.Contracts.Contract` implementations and carried on the
plan wire as declared data. The kernel names no
effect contract; a new mutation kind plugs in by implementing the behaviour
(id, validate_spec, plan_effect) and is found by
conformance, never by registration. Nothing executes the program: mutation
is the nix substrate's `workstation-switch` drivers (atomic generations,
rollback, publish); the engine's apply-time faces retired with the write
plane.

Effects declare their phase, and the declared order runs per-target effects
before the apply-phase effect — the ordering the nix program carries.

A CLI verb is a prefix of this list: `status` runs to `resolve`, `plan` to
`compose` (`Pipeline.verb_depth/1`). Read depths stay pure (no filesystem
probing beyond the per-target state report), so golden replay
is a function of its input bytes; the recorded plan body DECLARES its typed
effects (the deliberate golden re-record that pinned this shape is the
typed-effects plan change, rationale in its commit).

Goldens pin byte-identity of plan outputs across refactors; the nix
generation is the ownership and baseline story (eval-goldens guards the
walker's drift against the same recorded tree).

## Package self-containment (the law)

A package is self-contained: its manifest, payloads, profiles and
derivation logic live in exactly one place — the package's own tree,
outside the kernel. The kernel holds no package content and no package
mirror; discovery is the only path from the engine to a package. When a
package changes, exactly one tree changes — maintaining any package fact
in two places is a defect by definition, not a style issue. The store
mechanism (metadata plane, lockfile pinning, mirrors) is retired as a
direction: self-containment plus discovery is the whole distribution
story, and fresh-box parity consumes the package tree directly.

## Enforcement

A layer-law guard suite fails CI when a layer's forbidden vocabulary
reappears (kernel naming a package, platform naming a consumer, contract
naming an implementation) and when import direction inverts. The rules are
enforced in code, not prose.

## Module hierarchy & moduledoc conventions

The module tree mirrors the layers, and every module's moduledoc is the
architecture's documentation surface:

1. **Kernel — `Workstation.Core`** (graph, plan, digest, engine_state,
   json/canonical_json): pure
   machinery. Each kernel moduledoc states the kernel law: it names no
   package, backend, or consumer — it speaks only contracts and shapes.
2. **Contracts — `Workstation.Core.Contracts`** (the capability
   provider contract, download, mise, shell): handshakes, never
   implementations. A contract moduledoc names its purpose and states
   its implementor policy — where implementations live (package modules
   under `Workstation.Packages.*`) and that the engine discovers them,
   never lists them.
3. **Backends — `Workstation.Backends.*`** (chezmoi): one dialect per
   contract. A backend moduledoc names the dialect it owns — encoding,
   recipe contract, provider ids, argv — and that generic core may touch
   it only through this module API.
4. **Platform engines** (theme) stay kernel-side; their moduledocs are
   consumer-free by law: consumers derive, never named.
5. **Packages — `Workstation.Packages.*`**: everything concrete
   (specs, payloads, profiles). A package moduledoc names what it
   contributes and which contracts it consumes.

The layer-law guard suite (`ArchitectureDepsTest`,
`LayerLawTest`) enforces the namespaces, the forbidden vocabulary and
the import direction in code; a moduledoc that contradicts this section
fails the suite the same way a violated import does.

## Current state and debt

The discovery seed exists (runtime manifest discovery, conformance-
validated). Known debt being burned down: platform consumer records in the
theme engine. The retired increments — the download contract, the discovery
triplication, the resident nvim dialect — are the engine now, not debt.
Each remaining item is tracked as an increment against this document.
