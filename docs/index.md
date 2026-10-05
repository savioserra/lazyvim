# Repository reference

## Path map

| Path | Role |
| --- | --- |
| `README.md` | Install, apply, update commands |
| `AGENTS.md` | Repository-wide implementation rules |
| `tests/*.test.lua` | Graph/profile, provider contract, journal/preconditions, real backend renders, provisioning, CLI/update/launcher, cold bootstrap, package parity and isolated harness fixtures |
| `.github/scripts/test-apply.sh` | Scratch-home end-to-end apply test |
| `.github/workflows/ci.yml` | Platform matrix and lint |
| `.github/workflows/release.yml` | Tagged source archives |
| `workstation/packages/`, `workstation/versions.json` | Package-owned host provisioning, file recipes, payload assets and canonical pins |
| `workstation/bin/workstation` | Sole public lifecycle launcher; bootstrap installs the home symlink |
| `workstation/` | Package monorepo, lifecycle CLI, core, providers, engine state and versions |

## Documentation map

| Document | Scope |
| --- | --- |
| [`capabilities.md`](capabilities.md) | Dependency direction, contracts, lifecycle phases |
| [`chezmoi.md`](chezmoi.md) | Subordinate file backend, isolation, removals and guarded cutover |
| [`tools.md`](tools.md) | Managed tool inventory and platform coverage |
| [`testing.md`](testing.md) | Offline checks and isolated Linux container E2E recipe |
| [`secrets.md`](secrets.md) | 1Password boundary, vault scope, Pi skill policy |
| [`nvim.md`](nvim.md) | Editor entry points, profile, plugins, locks |
| [`tmux.md`](tmux.md) | Settings, plugin pins, theme |
| [`theme.md`](theme.md) | Shared color tokens, slot/palette layers, derived pi themes |
| [`herdr.md`](herdr.md) | Pinned Herdr binary and official Pi hook, ownership and compatibility gates |
| [`lua-migration.md`](lua-migration.md) | Runtime rationale and explicitly historical context |
| [`elixir.md`](elixir.md) | Elixir/OTP strangler migration: umbrella layout, CLI/TUI, daemon, parity goldens |

## Elixir migration policy (binding)

The Elixir surface (CLI, TUI, daemon, core) carries **no deprecated or
backward-compatibility APIs**: no legacy aliases, no compat shims, no dual
wire-schema versions — one current version, hard-cut. Lua code paths that are
deprecated/legacy and not pinned by parity goldens or tests are dropped (each
drop recorded in the migrating lane's report), and removals happen in the lane
that touches the code — delete, don't deprecate. This relaxes nothing else:
parity evidence (goldens, generation hashes, wire JSON) is never weakened, the
transitional `--engine` shell-out was strangler operations (not a compat API;
removed together with the Lua collector bridge in lane c5), and distribution
stays checksummed `mix release` tarballs only. The Elixir engine is described
by its own contract — code, comments, and docs never frame it as a "port" or "rewrite"; Lua
sources are cited only as parity anchors in tests and goldens, and migration narrative stays
in `docs/elixir.md`.
