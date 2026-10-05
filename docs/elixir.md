# Elixir migration

Umbrella scaffold and testing for the Elixir/OTP strangler migration of the
workstation engine. Policy (see the [index](index.md)): no deprecated or
backward-compatibility APIs — one current version per wire schema, hard-cut;
a Lua path retires only after its command graduates.

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
- Distribution: one checksummed `mix release` tarball + sha256 sidecar
  (linux glibc/libstdc++, see §1); never escript. macOS arm64 out of scope.

## Distribution

One artifact pair per platform, checked into `elixir/` (gitignored, rebuilt
locally):

```sh
cd elixir
mise exec -- env MIX_ENV=prod mix release workstation --overwrite
(cd _build/prod/rel && tar -czf ../../workstation-0.1.0-linux-x64.tar.gz workstation)
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

The canonical gate (`sh .github/scripts/check.sh`) also runs the umbrella
through `tests/elixir.test.lua`: it executes `mix test` only when `mise` is on
PATH, `elixir/deps` and `elixir/_build/test` are warm, and check.sh supplied
the real mise data dir (`WORKSTATION_MISE_DATA_DIR`, passed through the
test-home boundary). Any other state skips with a printed reason and exit 0 —
cold clones, missing toolchain, and nested meta-checks
(`WORKSTATION_NESTED_CHECK=1`) never pay the toolchain cost inside the gate.

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
`expected/{plan.json,manifest.json,generation.txt}`. Profiles: `minimal`
(foundation shell fragments), `full-home` (the complete catalog in declaration
order), `theme` (theme/tmux/agent closure: chezmoi-data envelope, template
files, symlink), `conflicts` (two declarers, one shared target: directory
merges plus an exact single-owner directory), `shell-order` (explicit fragment
order keys with the collection-order tie-break), `nvim-profile` (composed
profile intents with the same tie-break).

`input.json` is the only replay input: engine-agnostic normalized recipe
envelopes (`packages[].{id,requires,supported_hosts,contributes[].{provider,spec}}`,
inline `assets` map). Normalization is part of the contract: derived
`components` are dropped and re-derived through provider validation at replay
time; asset bodies are inlined under `"<package id>:<asset path>"`; absolute
symlink destinations under the recording home are pinned to `/home/golden`;
packages stay in construction order. Replay rebuilds recipes through the same
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
`Workstation.Daemon.Overlay` is the generic pubsub primitive (exclusive
domain ownership via `sub/unsub/pub`); theme demotes to a domain client —
its resolve matrix lives in `Workstation.Core.Theme` (pure core) and the
capability publishes resolved themes on the `"theme"` domain it registers;
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
the Lua update verb (`workstation/apps/cli/run.lua`) and the lifecycle
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

## Wire schema (retired lane b3 shell-out contract)

The b3 engine shell-out (`workstation/lua/workstation/report.lua collect
through the sanitized Engine bridge, schema `workstation.report` v1) was
retired by the c5 lane together with the collection flip: native live
collection (`Workstation.Core.Catalog.live/1`) replaced the collector and
the CLI evaluates every command in-process. The surviving CLI contract is
the output-wire schema below.

## CLI (apps/cli, `workstation` on the release PATH)

`workstation <status|plan|diff> --home <private root> [--json]` evaluates
the command in-process through the Elixir core (`Workstation.CLI.Core`):
the pipeline is the one the goldens grade, `Catalog.live -> Catalog.load ->
Graph.order -> Source.plan`, with native live collection — no engine
shell-out and no Lua anywhere in the path. The retired `--engine` and
`--core` switches are usage errors (exit 2). `--input <envelope.json>`
substitutes a recorded golden envelope for the live collection, so
`workstation plan --home <root> --input tests/goldens/minimal/input.json`
reproduces the recorded plan offline (no engine, no network; pinned by
`Workstation.CLITest`). `workstation json <status|plan|diff> ...` prints
the raw output-schema document for boundary debugging. ExUnit coverage
lives in `apps/cli/test/workstation/cli_test.exs`.

Safety guards (fail closed, never touch the real home):

- `--home` is mandatory (exit 2 without it) and must not equal the real
  `$HOME`;
- `--home` without a `.workstation-test-root` marker is refused (the marker
  is created by `.github/scripts/test-home.sh`, so only fixture homes
  pass);
- the state root (`WORKSTATION_HOME`) is bracketed around evaluation and
  restored, so the core reads exactly the selected `--home` and never the
  operator's state;
- before the fail-closed journal read, `EngineState` performs the same 0700
  state-root repair the Lua engine performed on every journal access
  (`state.lua guarded_directory`): a symlinked or foreign-owned component
  still fails closed.

## CLI output wires (lane b5 hard-cut schemas)

`Workstation.CLI.Output` defines exactly one schema per command; the Lua
reporter's `workstation.report/1` envelope stays an internal wire of the
Engine bridge and is never emitted as a CLI contract:

- `workstation.status.v1` — `{schema, engine{name, version, mode
  "lua"|"elixir"}, destination, platform, packages[{id, requires,
  supported_hosts}], graph_order, journal{generation, revision, at}|null}`;
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
| 2 | usage (unknown command/arguments, missing mandatory options) |
| 3 | conflict-or-precondition (core evaluation failed: bad envelope, graph or plan conflict, invariant) |
| 4 | backend-or-engine failure (engine bridge error, undecodable wire) |
| 5 | update backend failed (update wire undecodable / update bridge error) |
| 70 | unsupported engine wire schema (`InsufficientEngineSupport`, loud wire upgrade) |
| 77 | refused `--home` (real `$HOME` or missing test-root marker) |

Human TTY text for the core plan mirrors `changesets.lua print_report`
layout; the documented deviations keep the wire the single source of truth:
the plan header names the front end (the `plan.v1` envelope does not carry
the home path — destination is a status-wire field), modes print from the
wire's canonical octal strings, and patch headers never repeat the anchor's
duplicated `link` suffix.
