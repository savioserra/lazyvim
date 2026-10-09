# Workstation architecture

The engine is a **capability-speaking microkernel**. It knows what a capability
is — never which capabilities exist. Packages are self-describing carriers that
add capabilities to the host; a registry discovers them; the kernel resolves
and applies them. Dependencies between packages are declared, versioned, and
capability-keyed — never direct references.

## Layers and the law of each

1. **Kernel** — generic machinery: manifest discovery, dependency resolution,
   plan composition, precondition checks, apply, journal, verify. Speaks only
   contracts and shapes. Forbidden: the name of any package, backend, or
   consumer. The kernel cannot answer "is nvim installed"; it can answer "is
   the capability provided by package X satisfied".
2. **Contracts (ports)** — the technology-neutral capability surfaces:
   a thing that wants colors (theme), a thing that owns files (source), a
   thing that fetches pinned artifacts (download), a thing that composes
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

Dependency direction: packages → contracts → kernel, with backends plugging
into contracts. Never sideways by name, never downward.

## Discovery and resolution

The registry composes the catalog from whatever conforming manifest modules
ride the code path — never a hand-written registration list. Discovery is
deterministic (sorted, test-excluded, conformance-validated, duplicate-id-
rejecting). Resolution builds an acyclic graph over declared
provides/requires: orders dependents after dependencies, fails loudly on
missing requirements, incompatible versions, cycles, or contested
capabilities. Optional requires degrade gracefully instead of failing.

Adding a package — or swapping one (editor, terminal, agent runtime) — is
adding a manifest plus payloads. Zero kernel edits. An unknown package
self-serves every platform through contracts alone.

## The pipeline (the engine's one stage list)

The engine is ONE named stage list reduced over a `%Workstation.Pipeline.Run{}`
accumulator (`Workstation.Pipeline`):

    discover -> resolve -> compose -> check -> stage -> anchor ->
      interpret -> claim -> verify

Kernel modules implement stages — catalog discovery, dependency resolution,
plan composition, preconditions, staged publish, journal anchoring,
generation verification — and nothing else threads mutation state by
parameter. The execution itself is a FOLD: the plan's typed mutation program
(`Workstation.Pipeline.effects/1`: per-target effects first, the single
staged-generation apply effect last) is dispatched through DISCOVERED
`Workstation.Core.Contracts.Contract` implementations. The kernel names no
effect contract; a new mutation kind plugs in by implementing the behaviour
(id, validate_spec, plan_effect, run_effect, fingerprint) and is found by
conformance, never by registration.

Ordering is the invariant, not a preference, and the stage order IS the
ordering: preconditions run before any write; the pending attempt record
anchors before any effect runs; the applied provenance record lands only
after every effect succeeded; the generation directory is re-verified after
the fold. Effects declare their phase, and the fold runs per-target effects
before the apply-phase effect — a pinned artifact installs before the staged
generation applies.

A CLI verb is a prefix of this list: `status` runs to `resolve`, `plan` and
`diff` run to `compose`, `apply` runs to `verify` (`Pipeline.verb_depth/1`).
Read depths stay pure (no journal, no filesystem probing), so golden replay
is a function of its input bytes; the recorded plan body DECLARES its typed
effects (the deliberate golden re-record that pinned this shape is the
typed-effects plan change, rationale in its commit).

The journal anchors ownership and baseline; goldens pin byte-identity of
plan outputs across refactors; the apply lock serializes mutators.

## The package store (trajectory)

The same registry pattern extends off-host: a metadata plane (name +
version → manifest, dependencies, compatibility, checksums, artifact URL;
append-only, immutable once published) over an immutable artifact plane
(content-addressed, integrity-verified on install). Local discovery grows a
store source; the host pins exact versions + hashes (lockfile semantics) for
deterministic, reproducible installs; mirrors and vendoring fall out of the
same shape.

## Enforcement

A layer-law guard suite fails CI when a layer's forbidden vocabulary
reappears (kernel naming a package, platform naming a consumer, contract
naming an implementation) and when import direction inverts. The rules are
enforced in code, not prose.

## Module hierarchy & moduledoc conventions

The module tree mirrors the layers, and every module's moduledoc is the
architecture's documentation surface:

1. **Kernel — `Workstation.Core`** (graph, plan, journal, apply,
   preconditions, digest, engine_state, json/canonical_json): pure
   machinery. Each kernel moduledoc states the kernel law: it names no
   package, backend, or consumer — it speaks only contracts and shapes.
2. **Contracts — `Workstation.Core.Contracts`** (the capability
   provider contract, download, shell): handshakes, never
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
validated). Known debt being burned down: concrete dialects still resident
in the kernel (chezmoi name encoding, nvim profile composition), platform
consumer records in the theme engine, a flat package tree without the
declared domain axis, and the missing download contract. Each is tracked as
an increment against this document.
