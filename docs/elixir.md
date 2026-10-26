# Elixir migration

Umbrella layout of the workstation engine. The engine IS the Elixir/OTP
release; the Lua runtime is deleted outright (launcher fused, engine deleted,
lane fusion-final-r2 below). Policy (see the [index](index.md)): no deprecated
or backward-compatibility APIs — one current version per wire schema,
hard-cut; retired paths are deleted in the lane that retires them.

## Status

This section is the historical graduation trail of the Elixir migration
(lane records, evidence paths); the current surface is the read-only engine
described by the reference sections below. Retired verbs and machinery
named here (`apply`, `update`, `diff`, the journal, the baseline stamp)
are history, not instructions.

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
  `nvim-profile`, composing in collection order since the integer order keys died).
- Real-host re-sync after this lane is supervisor-owned (the launcher
  anchor fix means the host shim now exports the anchor itself; no env
  override needed).

## Architecture: capability/contract isolation (dep-guarded)

Two dependency rules are enforced by `ArchitectureDepsTest`
(`apps/core/test/workstation/core/architecture_deps_test.exs`, a
source-scan suite) and must never regrow:

1. **Theme engine is generic.** The theme engine (`Workstation.Core.Theme.Tokens`,
   the CLI theme resolver) exposes
   tokens + slots + palette. It must never name a
   consumer package: consumers derive from the tokens natively, in their
   own capability modules under `modules/` (nix-side) or their own view
   code (CLI-side). Dependency direction: consumer -> theme platform.
2. **Core names no consumer.** Generic domain modules must not reference
   concrete consumer packages — the declared state is the capability
   modules' report and the core speaks shapes.

(The backend-isolation and encoding laws retired with the chezmoi backend
in the absorption chain's stage 2 — the dialect they guarded has no
speaker. The historical three-law text lives in Git history.)

## Architecture: the read plane and the substrate (THE design)

The read plane answers from the BAKED EVAL REPORT in-process
(`Workstation.CLI.Output` — the flake's `evalReport` fold, `nix/report.nix`,
cached into the release at `share/workstation/eval-report.json` by
`nix/engine.nix`, so release and declared state ship from one flake
snapshot). Every read verb — `status`, `plan`, `capabilities`,
`json <command>` — evaluates the report for the resolved destination and
renders it; there is no resident engine process, no socket, and no wire
protocol. The daemon that used to serve these reads (and its pubsub/overlay
machinery — `EventBus`, `Overlay`, the `system`/`theme` domains) retired
with the read plane's move: a socket was a middleman for data the release
already carries. The same declared state answers directly from nix:
`nix eval .#evalReport.<system>.<field>`.

The write plane lives in the nix substrate: mutation is the
`workstation-switch` drivers (apply/rollback/update/sync) around
`home-manager switch` / `nixos-rebuild switch`. The driver's tail writes
the generation receipt — stdout plus the state tree's `switch.log` — and
the switch itself is the only event a generation carries: the activation
re-points the theme token path (`~/.local/state/workstation/theme.json`,
the theme module's store link), consumers read files or watch the link,
nothing polls and nothing publishes through the engine.

Stop polarity (the release control surface, by design): the bare
`workstation stop` verb is the release control surface
(`bin/workstation_ctl stop`): a dist-erl RPC to the node named
`workstation@<host>`, which only a `workstation start`-launched release
answers. There is no daemon to stop any other way — the socket era's
`workstation daemon` verb retired with the daemon.

## Distribution

One artifact pair per platform, checked into the repo root (gitignored, rebuilt
locally):

```sh
mise exec -- env MIX_ENV=prod mix release workstation --overwrite
(cd _build/prod/rel && tar -czf ../../../workstation-0.1.0-linux-x64.tar.gz workstation)
sha256sum workstation-0.1.0-linux-x64.tar.gz > workstation-0.1.0-linux-x64.tar.gz.sha256
```

- Never escript: the TUI needs the full OTP runtime, which an
  escript cannot carry.
- The shipped `bin/workstation` is the product CLI dispatcher (docs §CLI);
  the release control script it replaces lives on as `bin/workstation_ctl`
  (start/stop/eval/rpc — an ops surface).
- Runtime requirement: linux x86_64 with **glibc ≥ 2.17 and libstdc++**
  (`beam.smp` links `libc.so.6`/`libstdc++.so.6`/`libgcc_s.so.1` — verified
  in the lane b8 report); the bundled ERTS is built against the host glibc,
  so musl-only systems (Alpine) are unsupported. **macOS arm64 is explicitly
  out of scope** (release erts must be built on the target OS; no Darwin
  build host exists in this repo's acceptance set).
- Boot smoke: `sh tests/direct_boot.sh` verifies the sidecar checksum,
  extracts to a scratch dir, boots the release headless against a marked
  private test home and answers a live status read from the baked report
  (the wire must be canonical JSON with the pinned status schema and the
  resolved destination). It never touches the real `$HOME`.

## Launcher (workstation/bin/workstation) and the placed release

The public launcher is plain POSIX sh with exactly three jobs, then it is out
of the way:

1. **Sandbox**: symlink-loop resolution (≤40 hops), original rendezvous
   capture (`WORKSTATION_SESSION_*`), `DBUS_SESSION_BUS_ADDRESS` unset,
   `HOME`/`WORKSTATION_HOME`/`USERPROFILE`/XDG rebase to the destination.
2. **Anchor**: launched from an engine checkout (a `mix.exs` at the script's
   `engine_root`, or at its parent when the checkout is nested under
   `workstation/`), the launcher exports
   `WORKSTATION_ENGINE_REPO` so EVERY verb collects
   the checkout catalog; on a bare host no anchor exists and nothing is
   exported (installed-release behavior is unchanged). Gate:
   `.github/scripts/shim-anchor.sh` drives a verb through the
   shim in a test-home fixture with the env unset.
3. **Handoff**: UTF-8 locale guard, then `exec` of the placed release
   binary (`$HOME/.local/opt/workstation/bin/workstation`) — the Elixir
   engine IS the engine runtime; the launcher never interprets verbs. The
   release is placed by the nix switch drivers (the store path links into
   the home profile) or staged from a repo-root mix release on checkout
   hosts; the launcher acquires nothing.

The `~/.local/bin/workstation` symlink on the substrate is the nix
generation's link to the launcher; on a checkout host the operator points
it at the checkout shim. The historical engine-provisioned launcher
(`Update.Bootstrap`) and the installer-driven release refresh retired with
the write plane.

## Capability taxonomy

The declared capabilities and their foundation layers are REPORT data now:
the fold (nix/report.nix) maps each capability id to its foundation layer
(`foundation/base` for the foundation domain, `foundation/runtime` for the
languages, identity otherwise) and the status wire carries the rows
verbatim. The layers: `foundation/base` (foundation), `foundation/editor`
(editor), `foundation/runtime` (languages/*), `foundation/terminal`
(terminal), `foundation/agent` (agent), `foundation/theme`,
`foundation/fonts`, `foundation/secrets`. The declaration is status-wire
metadata only — it never enters the plan wire.

Capability order is the report's `capabilityOrder` (the walk's id sort —
nix/lib/capabilities.nix). The manifest-era edge-driven graph and its
ordering-field bans are history with the catalog arm.

## Layout

| Path | Role |
| --- | --- |
| `mix.exs` | Umbrella root (repo root): `apps/` path, hoisted `deps/` and `mix.lock` |
| `.tool-versions` | Repo-wide toolchain pin (Elixir 1.18.5-otp-27, Erlang/OTP 28.5): per-clone in-repo activation |
| `apps/core/` | `Workstation.Core.*` — pure engine port, zero runtime deps |
| `apps/cli/` | `Workstation.CLI.*` — optimus CLI, term_ui TUI (exact `2.0.0-rc.2` pin) |
| `tests/direct_boot.sh` | Release tarball boot smoke: checksum sidecar, headless boot, golden replay from a bare extract (never the real `$HOME`) |

Toolchain activation: the repo-root `.tool-versions` pins the battery
toolchain, so mise activates it automatically in-repo — plain `mise exec`
under the checkout resolves to the pins and the batteries command
(`mise exec elixir@1.18.5-otp-27`) is unchanged. The per-host side is
package-managed: the elixir package ships the activation fragment
(`.config/shell/mise.sh`, wired into the shell rc files as `managed-mise` —
the node package's managed-nvm pattern; bash/zsh eval the activate hook,
plain sh stays a guarded no-op) and the managed default-version config
(`.config/mise/config.toml`, whose `[tools]` table carries only the
elixir/erlang defaults — an existing foreign file conflicts instead of being
adopted).

Dependency direction: `cli -> core` — the read plane (`Workstation.CLI.Output`)
serves the baked report through the core's reader and state primitives;
there is no second engine app.

## Test

```sh
mise exec -- mix deps.get   # once, warms deps/
mise exec -- mix test       # umbrella suite
```

The canonical gate (`sh .github/scripts/check.sh`) is Elixir-native: the full
`mix test` umbrella suite, the byte-identical golden replay
(`mix workstation.goldens` into a scratch root, `diff -r` against
`tests/goldens`), `sh -n` + ShellCheck over the remaining shell scripts
(`workstation/bin/workstation`, `.github/scripts/*.sh`), the release boot smoke
when a local tarball is built, and `git diff --check`.

## Goldens (RETIRED — the replay contract's death record)

The recorded-envelope goldens (`tests/goldens/<profile>/` with
`input.json` + `expected/{plan.json,manifest.json,generation.txt}`) and
their machinery — `Workstation.Core.Golden`, the `mix workstation.goldens`
generator, the CLI's `--input` replay path, the direct-boot golden-byte
comparison — retired with the manifest format they pinned
(docs/absorption.md, the deletion chain's stage 2; the operator's binding
spec is "no byte-goldens"). Verification is behavioral: the read verbs
serve the baked declared-state report (proven by the read-mode tests and
the VM E2E read smoke), substrate verification is the VM/activation runs,
and the nix side's structural assertions live in the report fold's eval
(nix/report.nix). The historical contract text lives in Git history.

## Daemon (apps/daemon — RETIRED with the read plane's move; historical record)

The daemon app (`Workstation.Daemon.*` — the resident read server, the
pubsub hub, the `system`/`theme` overlay domains and the socket protocol)
retired when the read verbs moved to the baked eval report
(Workstation.CLI.Output): with the wire protocol's last client gone, the
user unit dropped from the home module and the app deleted with its tests.
This section remains only as the historical record of the semantics the
in-process read plane superseded.

`Workstation.Daemon.Application` booted one `:rest_for_one` tree — Listener →
Sessions → EventBus → CapabilityRegistry → OpRegistry → TaskSupervisor →
Overlay, then the
flattened `Workstation.Daemon.Capabilities.children/0` after them — so every
runtime dependency flowed strictly forward and any crash rebuilt the whole
serving generation in dependency order. The listener bound
`<home>/.local/state/workstation/daemon/<uid>.sock` (dir `0700`, socket
`0600`, no-follow owner/type guards over every state component — 0700,
current uid, no symlinks) and never touched `:gen_tcp`; the `:socket` API was used
with `family: :local` only. On `EADDRINUSE` it probed the endpoint with a
real hello handshake: a completed handshake meant a live generation and boot
failed with `{:already_running, path}`; connect-refused or mute endpoints were
dead and were unlinked (after an owner/type re-check) and rebound.

Wire format: 4-byte big-endian unsigned length + UTF-8 JSON;
`{v:1,id,op,params}` answered by `{id,ok:true,result}` or
`{id,ok:false,error:{code,message}}`; hello negotiates
`workstation.daemon/1` (mismatch closes), advertises the socket-auth
proof of the running generation (`"proof": "peercred" | "dir-owner"`) and
its pinned release generation (`"release"` — the rendezvous gate:
`Workstation.Daemon.Generation` pins the `.built-from` stamp beside the
node's own release root at boot, refuses a boot whose root stamp provably
differs from the installed release's, and at every hello re-reads the
installed stamp — a mismatch answers `stale_generation` and the daemon
stops itself gracefully, so ensure-daemon respawns from the fully staged
installed release; the client's ensure path verifies the same two facts
independently, liveness and control paths deliberately skip it);
caps — max request 1 MiB, max
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
carrier in `Workstation.Core.Theme.Tokens` (anchored to the theme
goldens fixture; re-branding edits both carriers — `tokens.lua` and the module). Secrets never
transit a schema and logs scrub params.

Lifecycle ops: the mutating surface is `apply.run` (generation + entries)
and `update.run` (a `steps` SUB-CHAIN — `pull`, `bootstrap`, `apply`,
`sync`, `verify` — or the whole lifecycle in one op), plus the bootstrap-
and reconciliation-only verbs `bootstrap.run`, `sync.run`, `verify.run`
that the CLI's like-named verbs route to. Both mutating ops serialize
through the orchestrator's apply lock — the same lock file the one-shot
apply takes — at different scopes: `apply.run` runs its whole pipeline
inside one acquisition, `update.run` acquires PER STEP (`bootstrap`,
`apply`, `sync`; `pull` and `verify` are lockless). The `not_graduated`
graduation gate (`Workstation.Daemon.Apply.enabled?/0`, flipped open at
graduation) covers the `apply.run` op ONLY — the `update.run` chain is
deliberately never gated, because `bootstrap` installs the release the
daemon itself runs from; the op surface, wire schema, and lock
serialization never churned across the flip. Flag-off behavior still
answers `not_graduated` on `apply.run`, and the flag-off refusal
tests stay. Reads (`status.run`/`plan.run`/`diff.run`) serve the hard-cut
wires from the daemon's own pinned home; `apply.plan` serves the apply
verb's confirmation wire — the SAME apply-mode composition `apply.run`
executes (journal baseline, removal activation, retirements), projected
through the plan wire, read-shaped: no lock, no gate, no mutation —
`update.check` (read-only,
TTL-cached, see the architecture section) and `theme.resolve` complete the
surface. Ops that take perceptible time run in a supervised task
(`Workstation.Daemon.TaskSupervisor`) OUTSIDE the session process — the
session stays frame-responsive and forwards the op's event frames while
it runs; the op registers under its stream token in
`Workstation.Daemon.OpRegistry` so ANY session can deliver `op.abort`,
which the task honours at its next step boundary. A session serves one
op at a time; additional op frames queue behind it.

The screens' executors (`Workstation.CLI.TUI.Executor`) speak this surface
and surface a refusal as the only reachable mutation outcome; the pure
`dry_run_executor/1` stand-ins stay the screens' defaults so an accidental
unconfigured run can never mutate anything.

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
whose decoded uid ≠ the socket owner's uid is refused fail-closed.

Platform-aware proof (2026-10-14 darwin ruling): the boot resolves the
socket-owner proof ONCE (`Listener.resolve_proof/2`) and every handshake
records the marker (`"proof": "peercred" | "dir-owner"`). Linux is
byte-identical: the `SO_PEERCRED` sentinel decides, uid equality per
connection. On darwin the Linux option answers `:eopnotsupp`, so the boot
probes darwin's `LOCAL_PEERCRED` (`SOL_LOCAL` 0 / option 1, `struct xucred`
— uid also the second native int32, no pid field) and prefers it when the
probe proves it reachable; when it is not reachable without a NIF (the
expected pre-connection answer is `:enotconn`, and the pinned OTP has no
socketpair) the boot degrades EXPLICITLY to the dir-owner proof — the
socket lives under the 0700 state root, so a peer that connected IS the
owner uid and the per-connection check re-verifies the chain (0700 owned
dir + owned socket, no-follow) at every accept. The degrade is never
silent: the `why` is recorded in the proof, the marker rides the hello
handshake, and the boot log names it. Only a BROKEN kernel proof on the
primary (Linux) arm still fails closed with
`{:peercred_unavailable, why}`; an unsupported option must never kill a
darwin boot. The same ruling gives the stop path a platform-independent
pid: `daemon.stop`'s wire result carries the daemon's own OS pid, which a
Linux client ignores in favor of its `SO_PEERCRED` read (pid is the first
ucred field) and a darwin/dir-owner client uses because xucred has no pid
to offer.

## Update lifecycle (RETIRED — historical record)

The UPDATE lifecycle (`Workstation.Core.Update.*`, the daemon's
`Workstation.Daemon.Lifecycle`) retired with the engine's write plane: nix
owns updates (`nix flake update` in the anchor repo + a switch). The step
modules (`pull`, `bootstrap`, `apply`, `sync`, `verify`), the daemon
Lifecycle capability and the generation rendezvous are deleted; this
section remains only as the historical record of the semantics the nix
drivers superseded.

* `pull` — checked fast-forward of the engine-owned checkout (fetch +
  `merge --ff-only`, never a destructive reset; git config pinned to
  /dev/null and `GIT_TERMINAL_PROMPT=0` so an update can neither read the
  operator's git configuration nor hang on a credential prompt);
* `bootstrap` — the versions.json-derived runtime install (pins derived
  fail-closed from the checkout's `versions.json`; the release refresh hands
  them to `install-runtime.sh` as env; digest-keyed caches, traversal-checked
  extraction, mkdir-lock serialized sibling-rename activation), the pinned
  chezmoi backend artifact, and the
  canonical public launcher symlink (conflicting paths are refused, never
  replaced);
* `apply` — a fresh server-side plan executed inline
  (the `Workstation.Pipeline` fold, apply phase) under the step's own
  apply-lock acquisition;
* `sync` — re-collect + plan reconciliation: the freshly built generation
  must still match the journal's applied generation;
* `verify` — launcher canonicity plus per-package fingerprint verification
  of every applied target against the journal's ownership record.

`update.run` serves a steps SUB-CHAIN per request (the whole lifecycle or
any suffix — the resume vocabulary below); locks are acquired PER STEP —
`bootstrap`, `apply`, and `sync` each take the exclusive apply lock the
one-shot apply serializes through, while `pull` and `verify` run lockless.
The c1 graduation flag (`Workstation.Daemon.Apply.enabled?/0`) gates the
`apply.run` op ONLY — the lifecycle chain is deliberately never gated,
because `bootstrap` installs the release (a chain that honored the gate
could never refresh the daemon's own code); with the daemon as the only
mutation engine the flag is OPEN in the shipped release (the daemon
refusing would leave no mutation path at all) and the flag-off refusal
tests pin the gate's shape. Step failures surface with the verbatim engine
message under the step's code (`update_failed` for pull/sync/verify,
`bootstrap_failed`, `apply_failed`); a flag-off `apply.run` answers
`not_graduated`; contention answers `locked`.
No step writes engine state outside the apply orchestration, and the
network-bound paths (git fetch, artifact download) have no external network
in tests: pull runs against local fixture repositories, bootstrap against
in-memory deterministic archive fixtures with pre-seeded or `file://`
caches behind the fixture-only `allow_file_urls` opt.

Release refresh INSIDE the chain (the hard part, daemon-side since the
client/server refactor): when the chain's `bootstrap` refreshes the
installed release, the daemon captures the writer identity BEFORE the
installer re-stamps the release (`.built-from` stamp; an in-place refresh
reuses the release root, so identity can never be the path), writes the
handoff note (`<state_root>/update/handoff.json` with the writer stamp and
the REMAINING steps), finishes the op with the `handoff` outcome, and
STOPS ITSELF (the running release just became stale code). The CLIENT
observes the disconnect mid-update, re-spawns the daemon from the
REFRESHED release (ensure-daemon, bounded handshake), and re-sends the
remaining chain — the fresh daemon validates the note's identity against
its own stamp, resumes the remaining steps under the same lock, clears the
note on success, and reports one chain. The aged-stamp discriminator
survives: the note of a DIFFERENT (aged) identity is consumed with no
handoff; a refresh-free bootstrap clears any stranded note (the
transitional self-heal); a failing resumed chain echoes the failure once,
never retried. Composition tests pin writer-before-stamp and
release-root child derivation.

### Journal record contract (2026-10-05 real-host incident)

An empty-catalog apply once wrote the real journal's revision 22 with
`targets`/`source_index` as JSON arrays (`[]`), and every later apply
refused to parse its own state ("journal source index is missing; rebuild
the plan" from `Changesets`, then Access crashes on the unguarded
`journal["targets"][target]` string-key lookups — latent at db477afe and
earlier). Two contract fixes, both regression-pinned:

* Engine-record JSON (the journal's applied/failed/pending records) is
  written with `Workstation.Core.CanonicalJSON.encode_record/1`: object-
  faithful — an empty map encodes `{}`, never the envelope's empty-object-as-`[]`
  rule that plan bytes must keep for golden byte parity.
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

Every read verb (`status`, `plan`, `capabilities`,
`workstation json <status|plan>`) evaluates the baked report in-process
(`Workstation.CLI.Output` — see the architecture section) and renders the
hard-cut wire; `json` prints the raw wire for boundary debugging.
On a usable terminal the bare verb opens the TUI dashboard; without a TTY
it prints the verb help (exit 0) — scripts pass `--headless` to the read
verbs, and a non-interactive run without the flag hard-errors.

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

### TUI application shell (the bare verb)

A bare `workstation` on a usable terminal opens the **TUI application
shell** (`Workstation.CLI.TUI.Shell`) — one full-screen app instead of a
prompt. The shell is a second Elm component (`TermUI.Elm`) whose mosaic IS
the app (no tabs): digits toggle the boxes, `p`/`P` cycling the
layout presets (full mosaic / audit / minimal, wrap-around; `--preset N`
pins the boot layout), `?` help-and-back, `q` quit — and the four-box
dashboard as the entire app: `1 engine` (identity + `●` read-state badge),
`2 capabilities` (the domain-grouped browser: `↑/↓` move, `enter` or `→`
expands a rollup down to packages then file rows, `←` or `backspace`
collapses — in-pane, never a tab switch), `3 plan` (the what-changed
summary with would-change/pending badges), `4 status` (the read's deep
rows). Enter toggles a box's in-box deep view (the read zoom), `r`
refreshes the reads over the read plane (`Workstation.CLI.Output` — the
baked eval report, the same surface the verbs answer) and every box has
explicit loading, empty and error states.

Mouse: `TUI.run` writes the SGR tracking bracket itself (`?1000` +
`?1006` on entry, both disable sequences in an after-clause — a crash
must never leave the terminal emitting mouse bytes); the pinned `term_ui`
runtime has no mouse support of its own. The shell routes `Event.Mouse`
in `Shell.event_to_msg/2`: a left press inside a zoomable box toggles
that box's deep view, the wheel
maps to the focused pane's `↑/↓` wherever the pointer
sits — over chrome included — and every other mouse event is ignored.
The bracket is pane-local, so under tmux mouse capture applies only
while the shell runs: after exit (clean or crashed) the terminal stops
emitting mouse bytes and tmux/terminal selection behaves as before.

(The historical `apply`/`update` screens — the typed-confirm overlays that
spoke the daemon's mutating ops — retired with the engine's write plane;
the dashboard is read-only by design and the write plane lives in the nix
substrate's `workstation-switch` drivers, so there is nothing to confirm
in-app. The TTY contract above governs the bare verb: a non-TTY bare
`workstation` prints the verb help and exits 0, never a hang. Tests drive
the shell through `TermUI.Runtime` with fake wires and recorded event
streams, so every state is replayable.)

Safety guards (fail closed, never touch the operator's state):

- the destination resolves `--home` > `$WORKSTATION_HOME` > `$HOME` (the
  launcher shim rebases both env vars to the same destination, so verbs
  address the intended home either way);
- read-side evaluation brackets `WORKSTATION_HOME` around the core and
  restores the previous value, so the core reads exactly the selected home
  and never the operator's state;
- `EngineState` keeps the guarded home reads: a symlinked or foreign-owned
  state component fails closed.

#### Home mosaic and box anatomy (hard contracts)

The home dashboard is responsive, and every boxed pane is built by one
builder (`Workstation.CLI.TUI.Shell.Box`). The contracts below are pinned
 cell-by-cell by `shell_home_frame_test.exs`, which renders the pure
`Shell.view/1` with loaded fixture wires — no daemon — across a full
width sweep (every width 80..240 at heights 24/40/55/83; a pinned
3-size matrix once missed whole width classes, e.g. the even mosaic
split at 204 columns, where content rows dropped a border column):

- **Width switch**: at >= 110 columns the four-box home is the slot
  mosaic — the top quadrants (engine, plan) plus the two
  full-width bottom bands (capabilities, status); below, the visible
  boxes stack full width in the priority order engine >
  capabilities > plan > status, each on a bounded-fill track that
  honors its minimum height and scales proportionally
  when the body runs short — a box is never clipped away, its content
  elides inside the still-closed borders.
- **Closed borders at every row**: every `╭` meets a `╮`, every `╰` meets
  a `╯`, and every rendered row is exactly the terminal width — and the
  border columns are IDENTICAL on border and content rows: a box's body
  rows carry both side borders on exactly the corner columns (`│ content
  │`; the right border swaps to the scrollbar glyphs while overflowing)
  at every swept size.
- **Full-width chrome bars**: the toggle strip (the top row) and the
  global footer each span every column — keycap islands ride the left
  edge and a chrome `─` filler carries the bar to the right edge (the
  strip never trails off into background blanks), with no blank cell
  anywhere on the strip or footer rows.
- **Island elision**: when a box narrows, the title and right-border
  islands ellipsis-trim (a cut reserves a cell for `…`) and then drop
  whole islands right-to-left; bottom buttonbars drop the position
  counter first, then trailing buttons, keeping the title island last.
  Corners never yield: degenerate widths fall back to plain closed
  corners.

Box anatomy (`Shell.Box`): the title is an island inside the top border
run (`╭─┐¹engine┌──…`), an optional right island carries counters and
badges (`──┐2/41┌─╮`), both side borders ride every body row on the
corner columns (`│ content │` — the right border swaps to the block
scrollbar `▲█▏▼` while the content overflows), and the bottom border
doubles as the box's buttonbar (`╰┘↑↓ scroll└┘r refresh└──┘1/41└╯`).
Title keycaps are btop's superscript digits (`Shell.keycap/1`, the
btop_draw.cpp:87 table) in the exact no-space btop construction
(`┐¹engine┌`), matching the strip order — the real 1..6 toggle keys (the
strip IS the keymap; a strip click
sends the same digit key that toggles the box). Every color arrives as a
text-role or theme-role style
from the caller; the builder hardcodes none (role inventory in
docs/theme.md, including the per-domain `border_*` panel roles).

## CLI output wires (the hard-cut read schemas)

`Workstation.CLI.Output` defines exactly one schema per command; no second
wire exists and none is emitted as a CLI contract:

- `workstation.status.v2` — `{schema, engine{name, version, mode "report"},
  destination, platform, counts, capabilityOrder, capabilities}` where
  `capabilities` are the report's accounting rows verbatim (id, foundation,
  the declared surfaces, retire) and `counts` is the report's counts object.
- `workstation.plan.v2` — `{schema, generation, declared, target_states}`.
  The `generation` is the report's content address (sha256 of the baked
  bytes); `declared` is the report's surface (fileTargets, claimTargets,
  retire, fragmentOrder); `target_states` is the per-target declared-vs-live
  probe. The declared-vs-applied diff story is the nix generation diff.

JSON emission is canonical (`Workstation.Core.CanonicalJSON`: sorted keys,
compact, empty maps as `[]`, explicit `:null` tokens), so identical state
yields byte-identical stdout.

## CLI exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | no usable terminal for an interactive verb (pass `--headless`) |
| 2 | usage (unknown command/arguments, missing mandatory options) |
| 3 | core evaluation failure (bad envelope, graph or plan conflict, invariant) |
| 4 | engine failure (native collection error, TUI failure) |

Human TTY text for the core plan keeps the canonical sections-and-layout;
the documented deviations keep the wire the single source of truth:
the plan header names the front end (the `plan.v1` envelope does not carry
the home path — destination is a status-wire field), modes print from the
wire's canonical octal strings, and patch headers never repeat the anchor's
duplicated `link` suffix.
