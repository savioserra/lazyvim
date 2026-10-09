# Store design (R4 direction — approved)

> **RETIRED** (user ruling, 2026-10-09 session): the store mechanism is not
> needed — package self-containment is the law (docs/architecture.md,
> "Package self-containment"); R4 lands self-containment and the v2.0.0
> release, and fresh-box parity consumes the package tree directly. This
> document is retained as retired history only.

Approved by the user 2026-10-09 following the language-package research
(`/tmp/fleet/reports/r4-store-language-packages-research.md`; precedents:
npm packuments + scopes, cargo sparse index, rustup components/profiles,
nodejs.org dist SHASUMS256, mise/asdf plugins). This document is the design
contract R4 tasks implement.

## Decisions

1. **Namespace-as-layout.** The domain axis is the registry namespace. A
   package id (`languages/node`) is simultaneously the index path, the
   workstation-tree path, and the capability namespace — the store never
   files a package under a category. Domain conflicts are impossible by
   construction; the catalog domain axis becomes the registry namespace with
   zero new concepts.
2. **Artifacts by-reference, pinned by hash.** Upstream stays source of
   truth (e.g. nodejs.org `/dist/v<ver>/` + `SHASUMS256.txt`); the store
   records artifact URL + sha256 at publish time and never rewrites
   versions. Mirrors are opt-in caches and must be byte-identical (the
   cargo source-replacement rule).
3. **Components + profiles for language packages** (rustup pattern):
   `minimal` (runtime only) / `default` (+ headers, package manager);
   host-overridable; components individually installable.
4. **The install split.** Artifacts install into an engine-owned versioned
   toolchain root (`~/.local/opt/<name>/<ver>/`), never into the dotfiles
   tree. HOME sees only contract outputs: shell PATH fragments, config
   templates, derived themes.
5. **Contracts are the install machinery.** download (artifacts, fail-closed
   hash), git (source-built tools), chezmoi (HOME payloads), shell (PATH),
   theme (derived colors), verify (`node --version == pin` — the existing
   runtime-verify pattern generalized). The store adds discovery,
   resolution, lockfile pinning — not a new install system.

## End-to-end flow

    workstation install languages/node[@<ver>]
      -> index lookup by id -> resolve dist-tag (lts/latest) -> exact version
      -> lockfile records version + artifact sha256
      -> download contract fetches (hash fail-closed) -> toolchain root
      -> components per profile -> chezmoi payloads -> shell PATH update
      -> runtime verify -> capability `language:node` provides

Publishing: package dir (manifest + templates + verify) -> `workstation
publish` -> append-only index record (versions immutable; yank/deprecate are
metadata). A second host replays the lockfile into identical state (R5's
parity proof).

## Open questions (resolve during R4)

- Index-record signing: per-release GPG/minisign vs npm-provenance-style
  attestations.
- Capability conflict policy for overlapping `language:*` providers
  (node vs bun as JS runtimes): resolver arbitration rules.
- Toolchain-root GC policy (unreferenced versions, disk bounds).
