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
  try/rescue/catch (Workstation.Daemon.Update.guarded/1); keep engine
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
