# Elixir migration

Umbrella layout of the workstation engine. The engine IS the Elixir/OTP
release; the Lua runtime is deleted outright (launcher fused, engine deleted,
lane fusion-final-r2 below). Policy (see the [index](index.md)): no deprecated
or backward-compatibility APIs — one current version per wire schema,
hard-cut; retired paths are deleted in the lane that retires them.

## Status

- Scaffold (lane b1): umbrella compiles, `mix test` green, placeholder tests
  per app. Superseded by the command graduations below.
- Graduation order (policy): status → plan/diff → apply → update. A command
  graduated only after its goldens matrix and the old-vs-new harness
  (`/tmp/fleet/b8_harness/harness.sh` — Lua reporter vs Elixir core on the
  recorded envelopes) were green for it; see the per-command evidence in the
  lane report (`/tmp/fleet/reports/b8-graduation.md`).
- **Graduated (lane b8): `status`, `plan`, `diff`.** The CLI default is core
  parity mode: in-process Elixir evaluation everywhere, no engine shell-out.
  The retired `--engine`/`--core` switches are usage errors; collection is
  native since lane c5 (`Catalog.live/1`) and the Lua collector bridge is
  deleted. Re-verified on
  the real host in lane c3: the Elixir plan reproduces the Lua engine's
  generation byte-for-byte (`e4b7736…`, 48 entries), and the changesets
  listing shows 48 active rows with zero retire rows and zero
  `.chezmoiremove` aggregate rows.
- **Graduated (lane c3): `update`.** Full lifecycle green on a sandbox home
  (`/tmp/fleet/c3/updateC.log`): sync + verify green (12 packages, 0
  drifted), host-drift refusal fail-closed (`update_failed` on a mutated
  target with the journal untouched), reconcile apply, idempotent rerun —
  revisions 5→6→7, generation stable `1055abdb…`. A real-host update is not
  required: it reuses the apply path and the read side already covered, and
  a real mutating run would trip the same zero-diff tripwire that blocks
  apply (below).
- **`apply` (lane c3): sandbox-graduated; real reconcile apply fired (lane
  c5, authorized).**
  The full daemon apply cycle is green on a sandbox home
  (`/tmp/fleet/c3/cycleC.log`: two consecutive zero-patch applies, journal
  revisions advancing, generation stable, verify green). The c3 real-host
  run flipped the flag, booted the daemon against the real state root, and
  verified the read side (plan 227 ms, diff 47 ms, generation parity with
  the Lua engine) — then stopped per the zero-diff tripwire: the engine's
  own plan reported a 2-patch add delta (`.pi/agent/agents/reviewer.md`,
  `.pi/agent/agents/worker.md`) because the journal baseline (revision 15,
  generation `8419e53d…`) predated the agent-recipe entries in the tree,
  while the deployed files already existed byte-identical. Lane c5 closed
  that runbook under supervisor authorization (Option A, guardrailed):
  after re-hash verification the two unowned files were removed so the
  engine re-added them as OWNED records (the ownership precondition's
  refusal to adopt unrecorded files was honored, not worked around), the
  reconcile apply fired, and the journal advanced exactly revision 15 → 16
  at generation `e4b7736…` with both files owned byte-identical, the
  real-host `workstation diff` empty, the post-apply patch delta empty
  (idempotent no-op), `workstation verify` exit 0, and all 46 pre-apply
  owned targets byte-identical (zero disk mutation beyond the journal).
  Engine fix required by the real host: `Source.with_baseline/2` stamps the
  true journal baseline at the daemon's composition boundary (the
  pure-replay plan's `journal_revision: 0` made every real apply look
  stale); pinned by the journaled-home invariant test in
  `apps/daemon/test/workstation/daemon/apply_test.exs`. Evidence:
  `/tmp/fleet/c5/reconcile_evidence.json`, `/tmp/fleet/reports/c5b-retirement-finish.md`.
- **Lua engine retirement (lane c5): partial, core retirement BLOCKED.**
  [SUPERSEDED by lane fusion-final-r2 — the block and every unblock rung
  below are resolved; history retained for the graduation trail.]
  Retired: the collect bridge (`workstation/lua/workstation/report.lua`,
  the CLI Engine client, the sanitized bridge boundary and its specs), the
  Lua golden generator (`golden.lua`), and every Lua suite without a
  surviving subject — `report` and `goldens` (the Lua-side suites are gone
  with their modules; the surviving `capabilities`, `backend-render`,
  `check`, `package-provision`, `provider`, `provision`, `correction`,
  `journal`, `cli`, `theme` suites test the still-present Lua core, so
  they stay). The public launcher and `run.lua` are unchanged: `run.lua`
  keeps all of its verbs (`apply`, `update`, `setup`, `sync`, `verify`,
  `diff`, `plan`, `status`, `bootstrap`) because they still have no
  Elixir executor — the CLI has no lifecycle verbs and refuses real homes
  by its graduated safety contract. BLOCKED: deleting the remaining Lua
  core (`source.lua`, `provisioner.lua`, `catalog.lua`, `changesets.lua`,
  `provision/*`, `run.lua`'s remaining verbs, and the launcher fusion
  itself) — the fusion would orphan the repo's still-canonical generation
  reconciliation: the Elixir CLI has no `apply`/`update`/`sync` lifecycle
  verbs yet (the daemon apply surface exists and now serves authorized
  real mutations, but it needs a live daemon; the launcher cannot fuse to
  a CLI that refuses real homes) and the policy tombstone would orphan
  apply/verify invariants with no native equivalents (verify parity proven
  only over retired-code fixtures; journal `generation.txt` anchors the
  Lua manifest bytes). Full inventory and unblock order in the c5 lane
  report; the tree is green with the Lua core still on disk. The c3
  journal-reconciliation precondition is resolved (lane c5 fired the
  authorized reconcile apply, revision 15 → 16), which removes one
  unblock rung but not the block itself: the Elixir CLI still has no
  `apply`/`update`/`setup`/`sync`/`verify` lifecycle verbs, so rerouting
  `bin/workstation` would orphan the lifecycle verbs it exists to serve.
- **Launcher fused, Lua engine deleted, TUI-default contract, catalog
  taxonomy (lane fusion-final-r2): COMPLETE.** The c5 blockers are resolved
  in order: the Elixir CLI gained the full lifecycle (`bootstrap`, `apply`,
  `update`, `sync`, `verify`, `pull` — interactive-first with the TUI as the
  default and `--headless` for non-interactive runs), the composition
  (`collect -> graph -> plan -> baseline`) exists once in
  `Workstation.Core.Plan` and is shared by the daemon applier and the one-shot
  driver, and the c5 journal-reconciliation precondition had already fallen.
  This lane deleted `workstation/lua/workstation/**` and every Lua suite
  whose subject died with it, fused `workstation/bin/workstation` to
  sandbox + runtime/release acquisition + exec of the engine release (the
  engine provisions the `~/.local/bin/workstation` launcher and refreshes
  its own release from the checkout), rewrote the check matrix Elixir-native,
  and declared the catalog taxonomy (foundation/* layers, status-wire
  metadata, byte-neutral for plan bytes and goldens). Goldens are
  byte-identical; the terminal contract holds on the release binary (PTY
  smoke engages the TUI, non-TTY without `--headless` exits 1 with the
  terminal error, `--headless` publishes normally), and the real host is
  green end-to-end: `verify` exit 0, `diff` empty, one true no-op apply
  advanced the journal exactly revision 19 → 20 with the generation stable
  (`e4b77364…`). Engine-path purity: the only `nvim` invocation left in the
  Elixir tree is the runtime-acquisition pin check (`System.cmd(nvim,
  ["--version"])` in `Update.Bootstrap.verify_runtime!/2`) — the managed
  capability verifying its own payload, never the engine executing through
  nvim. See the lane report for the deleted-file inventory and the residual
  capability-layer notes (tool/plugin provisioning that the Lua handlers
  owned).
- Distribution: one checksummed `mix release` tarball + sha256 sidecar
  (linux glibc/libstdc++, see §1); never escript. macOS arm64 out of scope.
- **Launcher repo anchor + package autodiscovery (lane autodiscovery):
  COMPLETE.** The launcher now resolves the checkout repo anchor for EVERY
  verb (not only bootstrap): launched from a checkout it exports
  `WORKSTATION_ENGINE_REPO`, so a bare `workstation apply` on the real host
  collects the checkout catalog instead of failing with the anchor-blind
  engine error (exit 4); a bare host exports nothing (gate:
  `.github/scripts/shim-anchor.sh`, a non-bootstrap verb through the shim in
  a test-home fixture with the env unset). The hand-written registration
  list is gone: package specs are DISCOVERED via the
  `Workstation.Core.Catalog.Spec` behaviour (`:code.all_available/0` +
  conformance, deterministic test-tree exclusion by the beam's recorded
  compile path, actionable shape/duplicate-id errors) — adding a package is
  dropping in a conforming module under
  `Workstation.Core.Catalog.Packages.*`, zero engine edits. `Workstation.Core.Graph`
  adds optional ordering-only `after` edges (systemd `After=` semantics:
  sequence only when the target is present and enabled; no necessity, no
  pull-in), keeps `requires` necessity, resolves dependency-equal ties by
  id sort (declaration order is dead) and reports cycle paths in cycle
  errors. Integer ordering fields (`order`/`position`/`priority`) are
  banned on package specs and recorded envelopes — rejected at discovery
  and load. Goldens re-recorded from discovery with the per-pair reorder
  justification in the feat commit message; no reordered pair is
  load-bearing (all `requires` edges still precede their dependents; the
  only semantic-adjacent move is the synthetic tied intent pair in
  `nvim-profile`, deliberately tied at intent order 20).
- Real-host re-sync after this lane is supervisor-owned (the launcher
  anchor fix means the host shim now exports the anchor itself; no env
  override needed).

## Distribution

One artifact pair per platform, checked into `elixir/` (gitignored, rebuilt
locally):

```sh
cd elixir
mise exec -- env MIX_ENV=prod mix release workstation --overwrite
(cd _build/prod/rel && tar -czf ../../../workstation-0.1.0-linux-x64.tar.gz workstation)
sha256sum workstation-0.1.0-linux-x64.tar.gz > workstation-0.1.0-linux-x64.tar.gz.sha256
```

- Never escript: the TUI and the daemon need the full OTP runtime, which an
  escript cannot carry.
- The shipped `bin/workstation` is the product CLI dispatcher (docs §CLI);
  the release control script it replaces lives on as `bin/workstation_ctl`
  (start/stop/eval/rpc for the daemon boot path and ops).
- Runtime requirement: linux x86_64 with **glibc ≥ 2.17 and libstdc++**
  (`beam.smp` links `libc.so.6`/`libstdc++.so.6`/`libgcc_s.so.1` — verified
  in the lane b8 report); the bundled ERTS is built against the host glibc,
  so musl-only systems (Alpine) are unsupported. **macOS arm64 is explicitly
  out of scope** (release erts must be built on the target OS; no Darwin
  build host exists in this repo's acceptance set).
- Boot smoke: `sh elixir/test/direct_boot.sh` verifies the sidecar checksum,
  extracts to a scratch dir, boots the release headless against a marked
  private test home, replays `tests/goldens/minimal/input.json` and compares
  the plan/manifest/generation bytes against the recorded goldens — proving
  the release core is the same engine the goldens pin. It never touches the
  real `$HOME`.

## Launcher (workstation/bin/workstation) and host acquisition

The public launcher is plain POSIX sh with exactly three jobs, then it is out
of the way:

1. **Sandbox**: symlink-loop resolution (≤40 hops), original rendezvous
   capture (`WORKSTATION_SESSION_*`), `DBUS_SESSION_BUS_ADDRESS` unset,
   `HOME`/`WORKSTATION_HOME`/`USERPROFILE`/XDG rebase to the destination.
2. **Acquisition** (bootstrap only): `workstation/bootstrap/install-runtime.sh`
   installs the pinned editor runtime and, when driven from an engine checkout
   with a `mise` toolchain, builds the engine release from `elixir/` and stages
   it under `$HOME/.local/opt/workstation` (private, engine-owned).
3. **Anchor**: launched from an engine checkout (an `elixir/mix.exs` sibling
   of the script's `engine_root`, or `engine_root` itself when the checkout is
   nested under `workstation/`), the launcher exports
   `WORKSTATION_ENGINE_REPO` so EVERY verb — not only bootstrap — collects
   the checkout catalog; on a bare host no anchor exists and nothing is
   exported (installed-release behavior is unchanged). Gate:
   `.github/scripts/shim-anchor.sh` drives a non-bootstrap verb through the
   shim in a test-home fixture with the env unset.
4. **Handoff**: `exec` of the installed release binary — the Elixir engine IS
   the engine runtime; the launcher never interprets lifecycle verbs.

The `~/.local/bin/workstation` symlink is provisioned and verified by the
ENGINE (`Update.Bootstrap` — refusing to replace conflicting user files), not
by shell. After `pull`, `bootstrap`/`update` refresh the installed release
from the checkout through the same installer (`Workstation.CLI.Engine
release_refresh`), so the launcher never outlives its engine.

## Catalog taxonomy

Every package declares the foundation layer it belongs to (`foundation:
"foundation/<layer>"` in its spec map; `Workstation.Core.Catalog.Packages.taxonomy/0`
is the closed map, `CatalogNativeTest` pins it). Declared layers:
`foundation/base` (the foundation package), `foundation/editor` (nvim),
`foundation/runtime` (node, go, elixir, typescript), `foundation/terminal`
(tmux), `foundation/agent` (agent, herdr, herdr-pi, pi-skills,
pi-ntfy-notifier), `foundation/theme`, `foundation/fonts`,
`foundation/secrets`. The declaration is status-wire metadata only — it never
enters graph resolution, envelopes or plan bytes, so catalog order and golden
bytes are unaffected.

Package ordering is edge-driven, never positional: `requires` edges carry
necessity plus ordering; the optional `after` edge is ordering-only and
applies only when the target is present and enabled; ties between
dependency-equal packages resolve by id sort. Integer ordering fields are
banned on package specs (`Workstation.Core.Catalog.Spec.validate!/2`).

## Layout

| Path | Role |
| --- | --- |
| `elixir/mix.exs` | Umbrella root: `apps/` path, hoisted `deps/` and `mix.lock` |
| `elixir/.mise.toml` | Toolchain pins: Erlang/OTP 28.5, Elixir 1.18.5-otp-27 (mise only) |
| `elixir/apps/core/` | `Workstation.Core.*` — pure engine port, zero runtime deps |
| `elixir/apps/cli/` | `Workstation.CLI.*` — optimus CLI, term_ui TUI (exact `2.0.0-rc.2` pin) |
| `elixir/apps/daemon/` | `Workstation.Daemon.*` — Zoi strict wire schemas, frame codec, protocol |
| `elixir/test/direct_boot.sh` | Release tarball boot smoke: checksum sidecar, headless boot, golden replay from a bare extract (never the real `$HOME`) |

Dependency direction: `daemon -> core`, `cli -> daemon + core` — one frame
codec and Protocol live in the daemon app; its supervision tree is inert in
CLI one-shot mode.

## Test

```sh
cd elixir
mise exec -- mix deps.get   # once, warms elixir/deps
mise exec -- mix test       # umbrella suite
```

The canonical gate (`sh .github/scripts/check.sh`) is Elixir-native: the full
`mix test` umbrella suite, the byte-identical golden replay
(`mix workstation.goldens` into a scratch root, `diff -r` against
`tests/goldens`), `sh -n` + ShellCheck over the remaining shell scripts
(`workstation/bin/workstation`, `workstation/bootstrap/install-runtime.sh`,
`.github/scripts/*.sh`), the release boot smoke when a local tarball is
built, and `git diff --check`.

## Goldens (Elixir replay contract)

`tests/goldens/<profile>/` holds byte-stable engine evidence. The canonical
re-record path is the native engine: `mix workstation.goldens` (umbrella root;
an explicit root argument records elsewhere — the default destination is the
repository tree, so regeneration must be a byte no-op on a consistent tree).
It drives `Workstation.Core.Golden` (elixir), the only generator since the
c5 retirement of the Lua engine: `project_plan/2` is the shared byte-parity
projection (generator and replay both call it, so the recorded and replayed
views cannot diverge), and `generate/0` emits the whole tree from the native
catalog with `nvim` composed natively since the c4b lane. The retired Lua
generator (`workstation/lua/workstation/golden.lua`, deleted with the collect
bridge) always ran through the private test-home boundary, never against the
real home. The drift anchor is `Workstation.Core.GoldenGenerateTest` (native
engine regenerates the committed tree byte for byte; `generation.txt`
addresses the exact manifest bytes), and `Workstation.Core.GoldenReplayTest`
replays every recorded profile and fails if any profile stops being replayed. Each profile directory contains `input.json` plus
`expected/{plan.json,manifest.json,generation.txt}`. reproduce the expected bytes exactly — a mismatch is an implementation bug;
expected bytes are never regenerated to match a wrong implementation.
Profiles: `minimal` (foundation shell fragments), `full-home` (the complete
catalog in discovery order — module-name sort), `theme` (theme/tmux/agent
closure: chezmoi-data envelope, template files, symlink), `conflicts` (two
declarers, one shared target: directory merges plus an exact single-owner
directory), `shell-order` (explicit fragment order keys with the
collection-order tie-break inside a package), `nvim-profile` (composed
profile intents with the same within-collection tie-break).

`input.json` is the only replay input: engine-agnostic normalized recipe
envelopes (`packages[].{id,requires,after?,supported_hosts,contributes[].{provider,spec}}`,
inline `assets` map). Normalization is part of the contract: derived
`components` are dropped and re-derived through provider validation at replay
time; asset bodies are inlined under `"<package id>:<asset path>"`;
absolute symlink destinations under the recording home are pinned to
`/home/golden`; packages stay in discovery order (module-name sort — the
record order is metadata only, execution order is derived per composition);
`after` lists are recorded only when declared (nil-drop, like every absent
field), and order/position/priority fields are rejected on both live specs
and recorded envelopes — integer ordering knobs are banned.
Replay rebuilds recipes through the same
domain validation the engine applies at collection (unknown fields rejected),
resolves the graph for `host`, plans against a fresh journal, and must
reproduce the expected bytes exactly — a mismatch is an implementation bug;
expected bytes are never regenerated to match a wrong implementation.

`expected/plan.json` is the normalized plan view (entries sorted by native
source name with name/target/operation/type/mode/attribution/bytes_sha256/
fingerprint plus declared link/exact/template; removals, unsupported
reversals, fragments journal, remove file, composed profile ids, data
envelope owner+bytes, journal revision, baseline generation).
`expected/manifest.json` and `expected/generation.txt` are the byte oracle:
canonical JSON (compact, object keys sorted ascending bytewise, arrays in
order, control bytes escaped, non-ASCII raw), the manifest array exactly as
specified in the golden generator header (construction order, field set,
array ordering), and `generation.txt` = sha256 of those manifest bytes.

The retired Lua-side suite (`tests/goldens.test.lua`, deleted with the Lua
generator in the c5 lane) generated every profile twice in two separate
engine processes and asserted all three trees byte-identical (generation ids
and fingerprints are content addresses and must not depend on per-process
encoder seeding), then asserted the committed tree matches exactly;
`Workstation.Core.GoldenGenerateTest` asserts the native side the same way.
The suite never rewrites goldens: drift means the engine or the inputs changed
and must be re-recorded deliberately, with the reason recorded in the lane
report.

## Daemon (apps/daemon, lane b6)

`Workstation.Daemon.Application` boots one `:rest_for_one` tree — Listener →
Sessions → EventBus → CapabilityRegistry → ApplyOrchestrator, then the
flattened `Workstation.Daemon.Capabilities.children/0` after them — so every
runtime dependency flows strictly forward and any crash rebuilds the whole
serving generation in dependency order (capability children start after the
registry and never outlive it). The listener binds
`<home>/.local/state/workstation/daemon/<uid>.sock` (dir `0700`, socket
`0600`, no-follow owner/type guards mirroring the Lua engine's `state.lua`
`guarded_directory`) and never touches `:gen_tcp`; the `:socket` API is used
with `family: :local` only. On `EADDRINUSE` it probes the endpoint with a
real hello handshake: a completed handshake means a live generation and boot
fails with `{:already_running, path}`; connect-refused or mute endpoints are
dead and are unlinked (after an owner/type re-check) and rebound.

Wire format: 4-byte big-endian unsigned length + UTF-8 JSON;
`{v:1,id,op,params}` answered by `{id,ok:true,result}` or
`{id,ok:false,error:{code,message}}`; hello negotiates
`workstation.daemon/1` (mismatch closes); caps — max request 1 MiB, max
response 16 MiB, 5 s frame-completion timeout, 300 s inter-frame idle
budget, 16-session ceiling, JSON depth ≤ 32; Zoi schemas are strict
(unknown fields/ops rejected). The served op set is assembled at compile time
from the capability registry (`Workstation.Daemon.Capabilities`, behaviour
`Workstation.Daemon.Capability` with `ops/0, schema/1, handle/3, domains/0,
children/0`); duplicate op or pubsub-domain names fail the build.
`Workstation.Daemon.Overlay` is the domain-ownership primitive (exclusive
`claim/release`, ordered best-effort owner delivery via `pub`, plus a
`{:domain, name}` event-bus fanout so followers observe domain events
without claiming ownership); theme demotes to a domain client —
its resolve matrix lives in `Workstation.Core.Theme` (pure core) and the
capability publishes resolved themes on the `"theme"` domain it claims;
hello advertises the union of registered domains. `theme.resolve` applies
overlay sets in explicit array order, later wins per role, over the palette
mirror in `Workstation.Core.Theme.Tokens` (byte-parity-anchored to the theme
goldens fixture; re-branding still edits only `tokens.lua`). Secrets never
transit a schema and logs scrub params.

Lifecycle ops (lane b8 graduation wiring): `apply.run` and `update.run` exist
so the orchestrator + TUI mutation path is live end-to-end. Both are
dispatched inside the orchestrator's apply lock — the same lock file the Lua
one-shot apply takes — and were held at the `not_graduated` gate until the
c3 graduation run flipped the flag: the op surface, wire schema, and lock
serialization never churned across the flip. Flag-off behavior (the shipped
default) still answers `not_graduated` for the mutating steps, and the
flag-off refusal tests stay. The screen-level executors
(`Workstation.CLI.TUI.Executor`) speak this surface and surface the refusal
as the only reachable mutation outcome; the pure `dry_run_executor/1`
stand-ins stay the screens' defaults so an accidental unconfigured run can
never mutate anything.

Peer credentials — recorded deviation (OTP 28 pin): the named `:peercred`
socket option is typespec-declared but unimplemented in the pinned OTP 28
`:socket` NIF (`prim_socket:supports/1` reports it unsupported; both the
2-arity and the 3-arity named forms raise `{:invalid,
{:socket_option, _}}`). Auth therefore reads the raw Linux form
`socket:getopt_native(sock, {1, 17}, 12)` (`SOL_SOCKET`/`SO_PEERCRED`,
12-byte `struct ucred = {pid, uid, gid}` with the auth field second). The b6
probe on the pinned toolchain returned `{:ok, <<0,0,0,0, 255,255,255,255,
255,255,255,255>>}` (pid 0, uid/gid -1 sentinel) for a pre-connection socket,
proving the option is live; real connections carry real creds and any peer
whose decoded uid ≠ the socket owner's uid is refused fail-closed. Because
auth is the daemon's only trust boundary, the listener verifies the
capability at boot and exits `{:peercred_unavailable, why}` rather than
serving unauthenticated.

## Update lifecycle (apps/core `Workstation.Core.Update.*`, apps/daemon `Workstation.Daemon.Update`)

The UPDATE lifecycle is ported one step per module, semantics anchored to
the retired Lua update verb (`workstation/apps/cli/run.lua`, deleted with
the engine in lane fusion-final-r2) and the lifecycle
phases of `docs/capabilities.md`:

* `pull` — checked fast-forward of the engine-owned checkout (fetch +
  `merge --ff-only`, never a destructive reset; git config pinned to
  /dev/null and `GIT_TERMINAL_PROMPT=0` so an update can neither read the
  operator's git configuration nor hang on a credential prompt);
* `bootstrap` — the `bootstrap.pins`/versions.json-bound runtime install
  (digest-keyed caches, traversal-checked extraction, mkdir-lock serialized
  sibling-rename activation), the pinned chezmoi backend artifact, and the
  canonical public launcher symlink (conflicting paths are refused, never
  replaced);
* `apply` — delegates to the engine applier (`Workstation.Daemon.Apply.run_current/1`)
  while already holding the orchestrator's apply lock;
* `sync` — re-collect + plan reconciliation: the freshly built generation
  must still match the journal's applied generation;
* `verify` — launcher canonicity plus per-package fingerprint verification
  of every applied target against the journal's ownership record.

`update.run` serves ONE step per request; every step runs under the same
exclusive apply lock the applier and the Lua one-shot serialize through.
The c1 graduation flag (`Workstation.Daemon.Apply.enabled?/0`, OFF by
default) gates the MUTATION steps (pull, bootstrap, apply) — the read-only
steps (sync, verify) serve regardless, so flipping the flag opens the
mutating steps without a wire change. The sandbox graduation ran with the
flag ON end-to-end (`/tmp/fleet/c3/updateC.log`); the shipped default stays
OFF and routine real-host mutation stays behind the operator's flag — the
one authorized real reconcile apply (lane c5, recorded in Status) advanced
the journal to revision 16 with an empty post-apply delta. Step failures
surface as `update_failed` with the verbatim engine message; gated steps
answer `not_graduated`;
contention answers `locked`.
No step writes engine state outside the apply orchestration, and the
network-bound paths (git fetch, artifact download) have no external network
in tests: pull runs against local fixture repositories, bootstrap against
in-memory deterministic archive fixtures with pre-seeded or `file://`
caches behind the fixture-only `allow_file_urls` opt.

### Journal record contract (2026-10-05 real-host incident)

An empty-catalog apply once wrote the real journal's revision 22 with
`targets`/`source_index` as JSON arrays (`[]`), and every later apply
refused to parse its own state ("journal source index is missing; rebuild
the plan" from `Changesets`, then Access crashes on the unguarded
`journal["targets"][target]` string-key lookups — latent at db477afe and
earlier). Two contract fixes, both regression-pinned:

* Engine-record JSON (the journal's applied/failed/pending records) is
  written with `Workstation.Core.CanonicalJSON.encode_record/1`: object-
  faithful — an empty map encodes `{}`, never the Lua empty-table quirk
  (`{}` → `[]`) that plan bytes must keep for golden byte parity.
  `encode/1` stays plan-faithful; `encode_record/1` is the journal seam.
* `Workstation.Core.Preconditions.check` fails closed before any ownership
  lookup when the journal's `targets` index is not a JSON object
  ("journal targets index is missing; rebuild the plan"), for the applied
  record and the pending-attempt path alike.

The empty-plan shape is itself pinned: an empty catalog applied to a fresh
test home records a parseable journal (`targets`/`source_index` = `{}`),
and a second apply over that journal succeeds.

## Wire schema (retired lane b3 shell-out contract)

The b3 engine shell-out (`workstation/lua/workstation/report.lua collect
through the sanitized Engine bridge, schema `workstation.report` v1) was
retired by the c5 lane together with the collection flip: native live
collection (`Workstation.Core.Catalog.live/1`) replaced the collector and
the CLI evaluates every command in-process. The surviving CLI contract is
the output-wire schema below.

## CLI (apps/cli, `workstation` on the release PATH)

`workstation <status|plan|diff> --home <root> [--json]` evaluates the read
side in-process (`Workstation.CLI.Core`); `--input <envelope.json>`
substitutes a recorded golden envelope for offline replay;
`workstation json <status|plan|diff> ...` prints the raw output-schema
document for boundary debugging.

Lifecycle verbs run the engine in this process (`Workstation.CLI.Engine`):
`bootstrap`, `apply`, `update`, `sync`, `verify`, `pull`. Mutations take the
target home's exclusive apply lock (`Workstation.Core.ApplyLock`,
`<state_root>/apply.lock`) — the same lock file the daemon orchestrator
takes — and compose their plan through the shared Core composition
(`Workstation.Core.Plan.composed_plan/2`). `apply` and `update` are
interactive-first: on a usable terminal they run the TUI screens; there is
no silent degradation.

## TTY contract (interactive-first, no fallback)

A terminal is usable when stdout is a real terminal and `TERM` is set and
not `dumb` (`Workstation.CLI.Router.usable_terminal?/0`). The TTY probe is
procfs-based and recorded: the release VM runs `-noshell`, where the classic
`:io.columns/1` probe answers `enotsup` even on a real PTY and
`prim_tty:isatty/1` is not callable from user code — so fd 1 is resolved
through `/proc/self/fd/1` (`/dev/pts/N`, `/dev/tty*`, `/dev/console` count;
pipes, sockets and `/dev/null` do not) and the `TERM` check runs on top.
Non-Linux or missing `/proc` reads as NOT a terminal — fail-closed toward
the explicit `--headless` flag, which is the intended contract direction.
On an interactive verb (`apply`, `update`):

- usable terminal, no flag → the TUI screens;
- `--headless` → the plain runner regardless of terminal state;
- otherwise (non-TTY, no `TERM`, or `dumb`) WITHOUT `--headless` → hard
  error, exit 1: `workstation: no usable terminal; pass --headless for
  non-interactive runs`.

Every internal non-interactive invocation (check matrix, test harnesses,
scripts) passes `--headless` explicitly. The heuristic's known limit: a
usable terminal behind a pager or multiplexer that strips `TERM` is treated
as unusable — pass `--headless` there.

Safety guards (fail closed, never touch the operator's state):

- the destination resolves `--home` > `$WORKSTATION_HOME` > `$HOME` (the
  launcher shim rebases both env vars to the same destination, so verbs
  address the intended home either way); there is no marker/refusal
  machinery on the CLI — the fused front door serves real homes, and the
  mutation gates ARE the contract: the TUI confirm screen (which echoes the
  collected plan and applies only the requested generation) or an explicit
  `--headless`;
- read-side evaluation brackets `WORKSTATION_HOME` around the core and
  restores the previous value, so the core reads exactly the selected home
  and never the operator's state;
- before the fail-closed journal read, `EngineState` performs the 0700
  state-root repair: a symlinked or foreign-owned component fails closed.

## CLI output wires (lane b5 hard-cut schemas)

`Workstation.CLI.Output` defines exactly one schema per command; the Lua
reporter's `workstation.report/1` envelope stays an internal wire of the
Engine bridge and is never emitted as a CLI contract:

- `workstation.status.v1` — `{schema, engine{name, version, mode "elixir"},
  destination, platform, packages[{id, requires, supported_hosts}],
  graph_order, taxonomy, journal{generation, revision, at}|null}` where
  `taxonomy` is the catalog's package -> foundation declaration
  (`foundation/<layer>`; descriptive metadata — it never enters envelopes
  or plan bytes);
- `workstation.plan.v1` — `{schema, generation, plan, manifest, patches,
  target_states}`. The `plan` body and `manifest` are the recorded golden
  artifacts verbatim (byte-identical to
  `tests/goldens/<profile>/expected/*.json`; nothing is added inside them —
  content-addressed parity bodies stay closed), while `patches` and
  `target_states` are the b5 additions at envelope level;
- `workstation.diff.v1` — `{schema, generation, backend_diff verbatim}`
  (the structured changeset records).

JSON emission is canonical (`Workstation.Core.CanonicalJSON`: sorted keys,
compact, empty maps as `[]`, explicit `:null` tokens), so identical state
yields byte-identical stdout.

## CLI exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | no usable terminal for an interactive verb (pass `--headless`) |
| 2 | usage (unknown command/arguments, missing mandatory options) |
| 3 | conflict-or-precondition (core evaluation failed: bad envelope, graph or plan conflict, invariant; apply-lock contention) |
| 4 | engine failure (native collection error, lifecycle step failure, TUI failure) |

Human TTY text for the core plan mirrors `changesets.lua print_report`
layout; the documented deviations keep the wire the single source of truth:
the plan header names the front end (the `plan.v1` envelope does not carry
the home path — destination is a status-wire field), modes print from the
wire's canonical octal strings, and patch headers never repeat the anchor's
duplicated `link` suffix.
