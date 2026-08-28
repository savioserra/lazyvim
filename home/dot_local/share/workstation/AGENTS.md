# Workstation lifecycle instructions

Scope: `home/dot_local/share/workstation/**`.

## Dependency direction

```text
apps/cli -> workstation.app -> workstation.catalog -> packages/*
                         \-> workstation.core/*
packages -> host/platform primitives
core -X-> catalog/packages/Neovim
```

## Module contracts

| Path | Contract |
| --- | --- |
| `apps/cli/run.lua` | Temporary Neovim-hosted lifecycle entry point |
| `lua/workstation/catalog.lua` | Explicit ordered package inventory; one entry per package |
| `lua/workstation/core/` | Domain-neutral contribution validation, materialization, graph, dispatch |
| `packages/<name>/` | Combined package metadata and lifecycle behavior |
| `lua/workstation/host/` | Reusable host primitives |
| `lua/workstation/platforms/` | Runtime-wide host detection, paths, base environment |
| `lua/workstation/app.lua` | Composition root; materializes catalog and creates runner |

## Add a package

1. Add one factory under `packages/` returning a combined contribution.
2. Include `id`, `requires`, `supported_hosts`, and optional `setup`, `sync`, `verify` fields.
3. Register the factory once in `workstation/catalog.lua`.
4. Keep complex helpers and feature-specific OS backends under that package.
5. Add ordering, unsupported-host, contract, and lifecycle tests.
6. Update package ownership and behavior documentation.

Package factories must be side-effect free when loaded. Do not use filesystem auto-discovery, generic deep merging, or handler overrides. Core must not import the catalog, packages, or Neovim modules.

Pi observer packages must keep `pi-subagents` authoritative. A terminal renderer receives only bounded sanitized projections and sends typed intents through authenticated IPC; it must never directly own, stop, resume, or recover a managed run. Renderer dependencies require an exact local lock, ignored lifecycle scripts, no native modules, and no target-host compiler.

`packages/subagents/` owns the inactive GoAkt service configuration boundary. Global AgentActors are independent of ephemeral Pi session actors: session shutdown removes access credentials, subscriptions, and views only, never a reusable AgentActor. The phase-1 `AuthorityBinding` remains a session-scoped observation of authoritative `pi-subagents`, not cross-session mutation authority.

## Lifecycle meanings

| Lifecycle | Scope |
| --- | --- |
| `setup` | Post-chezmoi host configuration |
| `sync` | Restore mutable application-managed state |
| `verify` | Assert pinned versions and observable behavior |

## Patterns

- Use `workstation.commands` for checked child processes.
- Use `context.paths` for target-home paths.
- Keep handlers idempotent.
- Clean temporary files and child processes on failure.
- Add a package-local backend when host behavior differs.
- Keep Neovim language entries in `home/dot_config/nvim/lua/languages/profile.lua`.
