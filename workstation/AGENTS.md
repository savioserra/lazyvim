# Workstation lifecycle instructions

Scope: `workstation/**`. The engine is Elixir-only
(`elixir/apps/core` + `elixir/apps/cli`): zero Lua execution and zero nvim
invocations in the engine path — nvim is a managed host capability, never an
engine dependency. This tree carries package payload and data only. Follow
[the engine reference](../docs/elixir.md) for module boundaries, graph
semantics and verification requirements.

## Add or change a package

1. Declare the package once as a pure-data contribution module under
   `elixir/apps/core/lib/workstation/core/catalog/packages/<name>.ex` and
   register it in `catalog/packages.ex` (declaration order is load-bearing:
   graph tie-break and golden construction order). No filesystem discovery,
   deep merging or handler overrides.
2. Keep payload assets under `packages/<domain>/<name>/files/` (and canonical
   dot-targets as `packages/<domain>/<name>/dot-*`); domains follow the
   package manifest's declared `foundation/<domain>` axis; recipes reference them
   package-relative and deploy only through declared recipes.
3. `.lua` files under `packages/` are DATA payloads (theme tokens, recorded
   pin tables), read or shipped as bytes — never executed by the engine.
4. Add ordering, unsupported-host, contract and lifecycle tests (Elixir,
   hermetic fixture homes). Update ownership docs and pin metadata together;
   the root safe-check entry point is `sh .github/scripts/check.sh`.

## Implementation patterns

- Desired-state composition (`Catalog.live` -> `Graph.order` ->
  `Source.plan` -> `Source.with_baseline`) lives once in
  `Workstation.Core.Plan`; apply/update surfaces call it, never re-derive it.
- Mutations run under the target home's exclusive apply lock
  (`Workstation.Core.ApplyLock`, `<state_root>/apply.lock`); immutable
  generations, the journal and precondition checks belong to the engine, never
  packages.
- Interactive verbs render the TUI when stdout is a terminal; non-interactive
  runs pass `--headless` explicitly (non-TTY without the flag hard-errors).
- Pi registry packages require exact integrity. Source-managed notifier
  verification currently checks manifest/files and mocked Node tests, **not**
  real Pi discovery or reload. Discovery/reload acceptance remains required
  separately; see [Pi resources](../docs/capabilities.md#pi-resources).
- Neovim profile composition and editor behavior belong to the
  [Neovim reference](../docs/nvim.md#profile-fields); do not import editor
  modules into core. Tool/plugin provisioning that the retired Lua handlers
  owned is a capability-layer concern, not an engine recipe.
