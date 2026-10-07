# Workstation fleet role memory (project scope, tracked in repo: worker writes, reviewer reads)

Machine-seeded 2026-10-04 by the supervisor session during the Elixir migration
fleet. Workers: append concise dated entries at the end; keep lines short; the
FIRST 200 LINES are injected into each run's prompt, so prune stale entries.
Reviewers: read-only recall — verify claims against these lessons, don't trust
them blindly.

This file is PROJECT memory: `.pi/agent-memory/fleet/MEMORY.md`, resolved for
any session working in this repo regardless of host. It is tracked in Git on
purpose — memory travels with the repo. The agent definitions that consume it
are engine-owned (`workstation/packages/agent/files/.pi/agent/agents/`) and are
provisioned to `~/.pi/agent/agents/` by `workstation apply`. Per-agent memory
is intrinsic to pi-subagents; Hermes/Pi parent memory is unrelated and not
required.

## Engine / repo conventions (/root/lazyvim)

- Gates use the 1/0/7 exit alphabet: 1=green (verified), 0=red (verified
  failure), 7=exceptional (couldn't verify — never fake 0/1). Preserve exactly.
- `sh .github/scripts/check.sh` is the mandatory final gate (tests + StyLua +
  sh -n + git diff --check under test-home.sh private roots). It can invoke a
  pager — set GIT_PAGER=cat / PAGER=cat in scripts to avoid hangs.
- Test suites run from repo root as `lua tests/<name>.test.lua`; private test
  homes come from tests/test-home.sh helpers, never the real $HOME.
- AGENTS.md change rule: one workstation package change = combined contribution
  + catalog + tests + docs edit in the same commit.
- Never edit deployed targets (~/.config, ~/.tmux.conf, ...) or
  ~/.local/state/workstation directly; repo source is the only write surface.
- Untracked WIP that must be preserved across lanes: tests/lua-workspace.test.lua,
  workstation/packages/rainfrog/, plus any active fleet WIP pile.

## Elixir / term_ui gotchas

- term_ui widgets: `Table.Column` is a struct (keyword-list opts fail);
  dimension tuples are {rows, cols} in that order. Verify struct shapes
  against the installed rc source, not memory.
- Zoi strict schemas reject unknown fields — protocol/event schemas must list
  every field or validation fails closed.
- mise-managed elixir (1.18/OTP28) lives in ~/.local/share/mise/installs —
  the release build uses the TOOLCHAIN dir, NOT the version dir; system
  /usr/bin/elixir+mix coexist and differ.
- BEAM CLI boots cost ~0.5–1s per invocation; escript for CLI verbs, daemon
  for hot paths.
- ExUnit failure output can paginate — set PAGER=cat / use
  `mix test --exclude ... 2>&1 | cat` in scripts.

## Fleet / pi-subagents mechanics

- Per-run `missionId` inside a workflow that already has a mission is fatal:
  "Use missionId or mission, not both". Mission attaches at workflow level
  only; children inherit.
- Fenced js workflow blocks get markdown-stripped when passed inline — write
  the script to a file and launch with workflow:"/abs/path.js"; preflight lane
  keys must match launched keys exactly.
- Agent definition catalog refreshes on extension-owned config mutations only;
  settings.json edits need /reload (dead mid-session). User-scope agent files
  (~/.pi/agent/agents/*.md) SHADOW builtins wholesale — after pi-subagents
  upgrades, re-diff the engine-owned copies in
  `workstation/packages/agent/files/.pi/agent/agents/` against the package
  builtins or prompts drift silently.
- Memory (this file) is injected 200 lines deep per run; worker appends,
  reviewer recalls. Prune aggressively; commit memory updates like any source
  change.

## Elixir build/FS gotchas (c2 lane, 2026-10-04)

- The pinned Elixir 1.18.5 build LACKS File.mv/realpath/symlink — use
  File.rename!/ln_s and a hand-rolled realpath (Workstation.Core.Update.realpath/1).
- File.lstat/1 returns {:ok, stat} tuples (bang returns bare). Pattern
  %{type: :regular} silently misses {:ok,...} — always match {:ok, %{...}}.
- A raise inside ApplyOrchestrator.with_lock's fun runs in the ORCHESTRATOR
  process: an uncaught non-ArgumentError kills it and the session gets an
  unrescuable EXIT (socket dies, no reply). Wrap locked step bodies in
  try/rescue/catch (Workstation.Daemon.Lifecycle.guarded/3); keep engine
  failures ArgumentError (ApplyEngine.run_backend now converts missing
  backend File.Error).
- This sandbox's /tmp has served STALE page-cache bytes for a just-tarred
  file under ExUnit create/delete churn (create→hash≠immediate re-read,
  converging per run). Never fixture "shell out to tar then hash the file":
  build deterministic archives IN-MEMORY (ustar+noo.gz — see
  apps/core/test/.../bootstrap_test.exs tar_fixture!/1) and hash the bytes
  you wrote.
- Core tests that touch the journal MUST set WORKSTATION_HOME to the sandbox
  (daemon-test pattern): Journal read guards anchor on EngineState.home()
  (global env), so without the env they silently depend on the operator's
  real ~/.local/state/workstation/journal and fail/skip under test-home.sh.
- check.sh's elixir gate runs the umbrella under the fixture HOME with
  MISE_DATA_DIR=shared; keep deps/ and _build warm for the canonical pin
  (elixir/.tool-versions: erlang 28.5, elixir 1.18.5-otp-27) or mix hits the
  interactive Hex prompt and the suite dies mid-output (exit 1, truncated log).

## Graduation lane lessons (c3, 2026-10-04)

- Lua `run.lua diff` is UMASK-SENSITIVE: it renders would-be applied modes
  through the process umask (chezmoi semantics). Under `umask 077` it
  fabricates all-file mode diffs (644→600). Run engine diffs under default
  umask; don't source env scripts that set umask before diffing.
- Elixir CLI `:diff` is a LISTING (always 48 rows on journaled homes); the
  mutation delta is `plan_doc["patches"]`. Journal baseline lags the tree
  after recipe additions → apply = generation advance, not byte no-op → the
  honest gate record is BLOCKED-FOR-SAFETY with the patch delta as evidence
  (runbook in docs/elixir.md; driver /tmp/fleet/c3/real_apply.exs refuses to
  fire unless delta empty).
- Core real-host fixes that sandboxes can't catch: CLI entry view must always
  carry a string `remove_file` (baseline-backed tombstone plans fail closed);
  `Catalog.load` must re-root live-profile symlink destinations from the
  canonical recording home to EngineState.home() under the state-root bracket.
- Sandbox install-apply cycle drivers must WIPE the fixture home each run
  (fresh-install preconditions refuse rendered-but-unowned targets); resetting
  only journal/generations is not enough.

## Native catalog lane (c4a, 2026-10-04)

- Elixir module attributes do NOT scope nested modules: bare `Foundation` in
  @package_modules resolves to top-level ::Foundation at runtime — alias
  Workstation.Core.Catalog.Packages.{...} explicitly.
- elixir/ has NO .formatter.exs and existing modules are NOT mix-format clean
  (hand-kept long-line style); never run bare `mix format` over existing
  files — only your own.
- [SUPERSEDED c5: golden.lua deleted — the oracle is `mix workstation.goldens`;
  see the c4b entry below] Test oracle pattern that worked pre-c5:
  `nvim -l workstation/lua/workstation/golden.lua <out>` with
  HOME/WORKSTATION_HOME/XDG_* pointed at a throwaway temp home; ~50 ms,
  records all 15 golden input.json envelopes. Golden recorder is
  test-only oracle for the native catalog equivalence (catalog_native_test.exs).

## Golden re-anchor lane (c4b, 2026-10-04)

- Golden recording is single-side since c5: `mix workstation.goldens` /
  Workstation.Core.Golden (elixir) is the ONLY generator; Lua `golden.lua` +
  `tests/goldens.test.lua` deleted in c5 (golden.lua survives only as a named
  parity anchor). Drift anchor: golden_generate_test.exs asserts vs committed
  bytes.
- Native package specs already carry `supported_hosts` as a host->true MAP —
  pass through verbatim; `Map.new` over a map mangles pairs into tuple keys.
- Shared projection pattern: `Workstation.Core.Golden.project_plan/2` is the only
  plan→recorded-view projection (generator + replay test both call it).
- `Catalog.canonical_home/0` ("/home/golden") is the single recorded-homes pin.

## Engine retirement + real-host baseline (c5/c5b, 2026-10-05)

- Real-host journal baseline is now revision 16, generation `e4b7736…`, 48
  entries (worker/reviewer agent definitions owned) — post authorized
  reconcile apply. Evidence: /tmp/fleet/c5/reconcile_evidence.json.
- Wire plan entry view identity key is `source_name` (never `name` — that
  spelling exists only in the golden projection); TUI/plain row ids and the
  apply.run entries map must use source_name (apply.ex entries_from_plan).
- `Source.with_baseline/2` stamps the real journal baseline at the daemon
  composition boundary; pure `Source.plan/1` carries journal_revision 0, so
  un-stamped plans fail preconditions on ANY journaled home (pinned by the
  journaled-home invariant test in daemon apply_test.exs).
- Zero-mutation snapshots must lstat SYMLINK targets (4 launcher links, mode
  0o120777, no sha) and treat dirs as mode-only; `.pi/agent` dir mtime churns
  from the live worker session itself — not an engine mutation signal.
- Full `workstation/lua/**` core retirement stays BLOCKED: bin/workstation →
  run.lua serves all lifecycle verbs (setup/verify/sync/apply/update) and
  real-home reads; the Elixir CLI has no lifecycle verbs and refuses real
  homes. Retired in c5: report.lua bridge, tests/report.test.lua, golden.lua,
  tests/goldens.test.lua, WORKSTATION_ENGINE_PRIV.

## Daemon arch lane (arch-capability, 2026-10-05)

- OTP `:socket` send/2 takes a BINARY only (iolist → ErlangError
  {:invalid,{:data,[...]}} → silent session resets); gen_tcp accepts iodata,
  :socket does not. Keep frame encoders returning binaries.
- Elixir bitstring gotcha: `<<x::unsigned-big-size(4)>>` is 4 BITS; a 4-byte
  BE length is `unsigned-big-integer-size(32)` (size(N) = N bits).
- Boolean-tree walkers: returning {:ok,_}/{:error,_} tuples into Enum.all?/2
  makes every branch truthy — keep walkers boolean, map at the boundary.
- Container-at-depth-0 must descend (guard `depth < 0 → false` BEFORE the
  map/list clauses) or deep payloads hide below the leaf threshold.
- Capability structure now: behaviour Workstation.Daemon.Capability +
  namespace Workstation.Daemon.Capabilities (@registry [Overlay,Theme,Apply,
  Update], Assembly raises on duplicate op/domain at compile time);
  Capabilities.{Theme,Overlay,Apply,Update} shells; theme matrix in
  Core.Theme; Overlay = generic pubsub (sub/unsub/pub, exclusive domains,
  pub is a synchronous call).

## Daemon capability architecture (arch lane, 2026-10-05)

- Daemon capability contract: `Workstation.Daemon.Capability` behaviour + `Capabilities` namespace; @registry [Overlay,Theme,Apply,Update]; Assembly raises on duplicate op/domain at COMPILE time; session dispatch = one clause via `Capabilities.dispatch/3`; hello stays a Protocol wire concern (ops = ["hello" | Capabilities.ops()]).
- `Workstation.Daemon.Overlay` is the generic pubsub primitive (sub exclusive by domain, pub is a SYNC call for deterministic delivery); theme = domain client; resolve matrix lives in `Workstation.Core.Theme` (pure core, string-keyed roles).
- OTP :socket send needs BINARIES — bitstring size is in BITS (`size(32)`), iolists break `:socket.send`; frame length = `<<size::unsigned-big-integer-size(32)>>`.
- Depth guard must walk validated containers only; params-optional for hello, required-else-invalid_params for op envelopes; Overlay.unsub must demonitor the REF, never the domain string.
- Capability children flatten AFTER infra children (Listener,Sessions,EventBus,CapabilityRegistry,ApplyOrchestrator) under :rest_for_one.

## Autodiscovery lane (2026-10-05)

- Catalog specs are DISCOVERED (Workstation.Core.Catalog.Spec behaviour +
  Discover, :code.all_available/0 filtered to the Packages.* namespace,
  test/support excluded via beam compile_info source path, module-name
  sort); @package_modules registry is GONE — adding a package = drop in a
  conforming module, zero engine edits.
- Integer ordering (order/position/priority) is BANNED on package specs and
  recorded envelopes; ordering is requires (necessity+order) or `after`
  (ordering-only, systemd After= semantics: applies only when target
  present+enabled, no pull-in); dependency-equal ties = id sort.
- :code.all_available/0 may list modules from a PREVIOUS compilation
  (Code.ensure_loaded can fail with {:error,:nofile}) — always filter by
  namespace prefix before touching modules, and treat "declared behaviour
  but spec/0 missing" as an error.
- Elixir map literal gotcha: `%{a: 1, key => v}` with a variable key is a
  syntax error — keyword shorthand must be last (%{key => v, a: 1}).
- inspect/1 strips the "Elixir." prefix from alias atoms (inspect(Alpha) ==
  "Alpha") — regexes on inspect output must not expect the prefix.
- Single-writer discipline: commit per green unit (feat → test → docs),
  never hold a large uncommitted batch across a deadline.

## Incident: 2026-10-05 17:37 real-host write (trust entry)

- A bare `mix test` run of `Workstation.CLITest.EnvContract` (cli_test.exs
  "--headless bypasses the gate" test) executed a REAL Router.main(apply)
  with `--home` pointed at a sandbox but the ENGINE STATE ROOT unbracketed:
  EngineState.state_root resolves WORKSTATION_HOME||HOME globally, under
  bare mix test that is /root, so the apply journaled revision 22 (empty
  mid-WIP plan) into PRODUCTION ~/.local/state/workstation. No `workstation
  apply` was typed — the suite itself was the mutator. Rule reinforced:
  ANY test that can mutate must pin WORKSTATION_HOME (and --home) to the
  fixture for the whole run; the two gate tests now do and assert the
  journal lands in the sandbox (24906b08).
- Journal record writes must use CanonicalJSON.encode_record/1 (object
  faithful, {} when empty) — encode/1 mirrors Lua {}→[] for golden parity
  and POISONED the real journal (source_index [] vs reader is_map) after
  the incident write; readers fail closed on list-shaped indexes
  (preconditions.check).
- `journal["targets"][target]`-style string-key Access on possibly-list
  journal fields crashed real applies on empty baselines — latent since
  db477afe; guarded fail-closed in 7235557d.

## Update/overlay lane (2026-10-05)

- Engine.guarded/3 step contract: EVERY lifecycle step closure takes ONE
  arg (merged run opts) — a zero-arity closure passes tests until the
  real update chain runs (BadArityError mid-chain at engine.ex:209);
  fixed in 51a80d3d, regression = headless run_update in a split-bracket
  fixture home (cli engine_test.exs).
- Journal.record_applied is home-ARG-anchored; Journal.applied's read
  guard is GLOBAL-env-anchored — under a split destination/state-root
  bracket the guarded read answers :absent; tests must assert the
  destination-anchored applied.json file directly.
- Overlay primitive is claim/release/pub (2026-10-05, 49877373): sub/
  unsub are GONE; pub/2 fans out every event on the EventBus
  {:domain, name} topic — standalone Overlay boots MUST start EventBus
  first (missing registry fails pub loudly, by design); theme followers
  subscribe to {:domain, "theme"} instead of claiming ownership.

## Release-refresh lane (2026-10-05)

- Update chain engine-upgrade contract (6d2665c2/7cc3f020): bootstrap step
  refreshes the installed release (anchor+platform+mise gated, .built-from
  stamp vs pulled HEAD skips no-ops, installer failure aborts); refreshed
  bootstrap leaves <state_root>/update/handoff.json and the plain runner
  re-runs remaining steps as `update --headless --resume-from <steps>`
  child (BEAM has NO exec(2) — child + exit-forwarding is the handoff).
- Update.engine_root VALIDATES candidates (bootstrap/bootstrap.pins +
  versions.json + bin/workstation) and falls through to the dev anchor on
  an invalid explicit root — fixtures for "checkout without elixir/" must
  carry the three anchor files AND be named .../workstation.
- Enum.reduce_while returns the {:halt, x} PAYLOAD unwrapped — outer case
  clauses match x, never {:halt, x}.
- Installer stamps releases with .built-from = source HEAD; a release
  without a stamp is always stale (conservative rebuild).
- Handoff/staleness identity MUST be content (installer .built-from stamp),
  never a path: an in-place release refresh reuses the same release root,
  so path identity made the refreshed code re-hand-off to itself forever
  (live 2026-10-05: each generation ran one more step, last spawned an
  EMPTY --resume-from → exit 2 cascade). Fixed in Engine.release_identity/1;
  unit-seam tests missed it because the fixtures never had writer/reader on
  the same path — identity tests need the in-place shape.
- System.cmd children inherit the full parent env (WORKSTATION_HOME
  bracket included) — do not blame launcher env re-export first when a
  spawned child misbehaves; check identity/argv contracts first.

## Handoff identity gotchas (P0 fix lane, 2026-10-05)

- Update handoff note names IDENTITY, never location; the child bin comes
  from the release ROOT — spawning the identity token as a path is the
  :enoent P0 (079a667e). Identity is captured, never re-read mid-chain:
  writer's BEFORE the installer re-stamps, caller's once at chain start.
- Seam-gap lesson: unit tests that inject path-shaped fakes through a
  seam can mask an identity-as-path conflation — add one composition test
  (real probe + real spawn derivation + shape-antagonistic value) for any
  identity-like handoff.
- :code.root_dir() under `mix test` is the mise erlang bin dir, not a
  release — any test exercising spawn-from-root must pass the fixture
  root explicitly (Plain :handoff_release_root seam).

## Client/daemon refactor gotchas (engine lane, 2026-10-06)

- term_ui 2.0.0-rc.2 backend replays recorded frames ONLY through the Elm
  loop: op tasks must run outside the screen (TermUI.Command.async/2) and
  event frames come back via TermUI.Runtime.send_message/2 — calling
  send_message/2 without a runtime (pid gone) crashes; guard by run ref
  and swallow {:error, :runtime_not_running}.
- Do NOT hold a Session's socket in an op task and send on it from two
  processes: only the session process sends frames (ErlangError otherwise);
  op tasks publish to the EventBus :op topic and the session forwards.
- file:// remotes need uploadpack.allowReachableSHA1InWant only for fetch;
  ls-remote works bare, but git ls-remote against a LOCAL path wants a
  repo with at least one ref — bare init + one commit, else
  "No local HEAD" ambiguity; prefer a real clone for behind fixtures.
- Exit-code contract tests: exit({:shutdown, code}) propagates through
  catch_exit/1 as {:shutdown, code}; mixing Process.exit(self(), code)
  (bare int) breaks exit/1 clause-matching — keep the tuple form.
- The graduation gate (Workstation.Daemon.Apply.enabled?/0) defaults OPEN
  since the daemon became the only mutation engine; flag-off refusal tests
  stay green via explicit Application.put_env in setup.

## Daemon-stop cycle + host-ops gotchas (supervisor, 2026-10-06)

- Optimus FLATTENS matched subcommand positionals: for argv ["daemon","stop"],
  result.args == %{action: "stop"} — result.args[:daemon][:action] is always
  nil. Pin parse shape through the REAL parser (Router.parser/0, made public)
  in daemon_verb_test.exs; audit grep "args[:daemon]" before adding verbs.
- Boot.run must Process.flag(:trap_exit, true) BEFORE Supervisor.start_link
  so failing child starts ({:error, {:already_running, sock}}) arrive as
  {:EXIT, sup_pid, reason} and render as rc-4 operator errors — otherwise the
  raw child EXIT kills the caller and the daemon survives a "stop".
- pgrep self-match trap: `pgrep -f 'Router.main.*-- daemon'` inside bash -c
  matches the WRAPPER's own cmdline (false "still running"/"booted one").
  Match 'beam.smp' or the release erts path instead; trust the daemon's own
  rc/output over process-grep invariants.
- Host release refresh: bare `workstation bootstrap` does NOT refresh an
  existing engine release (release_refreshed=false is honest — the shim skips
  when an engine exists). The refresh path is `workstation update` (bootstrap
  step rebuilds when $parent/workstation/.built-from != checkout HEAD; stamp
  written by install-runtime.sh). Rebuild by hand: cd elixir && mise exec --
  env MIX_ENV=prod mix release workstation --overwrite (tarball is a separate
  check.sh artifact, installer copies _build/prod/rel/workstation directly).
- Stop semantics ruling precedent (gate v3 d1): a clean stop leaves the
  0-byte socket FILE by design (listener.ex fail-closed: never unlink a
  socket you can't prove is yours; next boot proves-dead-and-rebinds).
  Gate criteria saying "socket gone" must mean ENDPOINT death (rc 0 +
  beam gone + status-over-stale-file reclaims), not file unlink.

## Keycap/border lane (c6, 2026-10-05)

- Elixir Regex on box-drawing rows: NEGATED classes are byte-wise without
  /u — `[^┌]` excludes the BYTES of ┌ (e2 94 8c), so it also rejects
  superscripts (U+2070-2079 share leading byte e2) and the match skips
  islands. Always append /u to glyph-munging regexes.
- Erlang :string.find/2 returns the SUFFIX from the match (not {pos,len});
  for a frame column use String.split(part, parts: 2) + String.length.
- check.sh's parallel umbrella run still races the ApplyTest/ShellTest/
  UpdateTest/DaemonVerb async-wire tests (different subset per run under
  load ~3; all green in isolation). New frame-race asserts should use the
  bounded await_frame helper from day one (tui_case.ex).
- Token surface is now v3: six closed border_* roles (engine/plan blue,
  journal/status green, capabilities yellow, diff red) across tokens.lua,
  Tokens.ex, daemon settable roles, CLI @roles; Tokens.border_roles/0 is
  the membership list. Regenerate goldens with `mix workstation.goldens`.
