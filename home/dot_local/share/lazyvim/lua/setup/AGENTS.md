# Setup runtime instructions

Scope: `home/dot_local/share/lazyvim/lua/setup/**`.

## Dependency direction

```text
app -> capabilities
app -> runtime
app -> features -> host/platform primitives

runtime -X-> capabilities
runtime -X-> features
capabilities -X-> runtime/features
```

## Module contracts

| Path | Allowed contents |
| --- | --- |
| `capabilities/*.lua` | `id`, `requires`, `supported_hosts` only |
| `runtime/contract.lua` | Generic capability schema validation |
| `runtime/graph.lua` | Selection and topological ordering |
| `runtime/runner.lua` | Generic lifecycle dispatch |
| `features/<name>/` | Setup, sync, verification, feature-local OS behavior |
| `host/` | Reusable host primitives |
| `platforms/` | Runtime-wide host detection, executable paths, base environment |
| `app.lua` | Composition and profile-derived dependencies |

## Add a capability

1. Add a data-only declaration under `capabilities/`.
2. Register it in `capabilities/catalog.lua`.
3. Add handlers under `features/`.
4. Register handlers in `features/catalog.lua`.
5. Add profile prerequisites only when editor composition needs the feature.
6. Add ordering, unsupported-host, and handler tests.

## Lifecycle meanings

| Lifecycle | Scope |
| --- | --- |
| `setup` | Post-chezmoi host configuration |
| `sync` | Restore mutable application-managed state |
| `verify` | Assert pinned versions and observable behavior |

## Patterns

- Use `setup.commands` for checked child processes.
- Use `context.paths` for target-home paths.
- Keep handlers idempotent.
- Clean temporary files and child processes on failure.
- Add a feature-local backend when host behavior differs.
- Do not add domain fields to the generic capability contract.
- Do not model Neovim profile entries as lifecycle capabilities.
