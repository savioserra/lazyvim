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

## Applying

One generic pipeline serves every mutation: collect manifests → resolve →
plan desired state → check preconditions → apply → journal → verify. The
journal anchors ownership and baseline; goldens pin byte-identity of plan
outputs across refactors; the apply lock serializes mutators.

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

## Current state and debt

The discovery seed exists (runtime manifest discovery, conformance-
validated). Known debt being burned down: concrete dialects still resident
in the kernel (chezmoi name encoding, nvim profile composition), platform
consumer records in the theme engine, a flat package tree without the
declared domain axis, and the missing download contract. Each is tracked as
an increment against this document.
