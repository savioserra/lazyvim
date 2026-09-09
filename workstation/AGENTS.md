# Workstation lifecycle instructions

Scope: `workstation/**`. Follow [the package and lifecycle contract](../docs/capabilities.md)
for module boundaries, graph semantics and verification requirements.

## Add or change a package

1. Add a side-effect-free factory under `packages/<name>/` returning one combined
   contribution: `id`, `requires`, `supported_hosts`, optional `setup`, `sync`, `verify`.
2. Register it once in `lua/workstation/catalog.lua`; no filesystem discovery,
   deep merging or handler overrides.
3. Keep complex helpers and feature-specific OS backends package-local. Reuse
   `lua/workstation/commands.lua`, `lua/workstation/paths.lua` and
   `lua/workstation/provision.lua` for checked children, target paths and archive
   provisioning. `lua/workstation/platforms/` is for runtime-wide environment only,
   never feature workflows.
4. Add ordering, unsupported-host, contract and lifecycle tests. Update ownership
   docs and pin metadata together; use the root safe-check entry point.

## Implementation patterns

- Use `workstation.commands` for checked children and `context.paths` for target paths.
- Keep handlers idempotent; clean temporary files and child processes on failure.
- Keep the materializer's metadata/handler split explicit and core domain-neutral.
- Pi registry packages require exact integrity. Source-managed notifier verification
  currently checks manifest/files and mocked Node tests, **not** real Pi discovery
  or reload. Discovery/reload acceptance remains required separately; see
  [Pi resources](../docs/capabilities.md#pi-resources).
- Neovim profile composition and editor behavior belong to the
  [Neovim reference](../docs/nvim.md#profile-fields); do not import editor modules into core.
