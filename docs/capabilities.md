# Capability and runtime reference

## Dependency direction

```text
run.lua
  -> setup.app
      -> capabilities/catalog -> capability data
      -> runtime/graph + runtime/runner
      -> features/catalog -> feature handlers -> host/platform primitives

runtime      -X-> capabilities/features
capabilities -X-> runtime/features
```

`setup.app` is the composition root.

## Module boundaries

| Path | Contract |
| --- | --- |
| `setup/capabilities/*.lua` | Data: `id`, `requires`, `supported_hosts` |
| `setup/capabilities/catalog.lua` | Ordered capability inventory |
| `setup/runtime/contract.lua` | Generic policy validation |
| `setup/runtime/graph.lua` | Host selection, dependency validation, topological ordering |
| `setup/runtime/runner.lua` | `setup`, `sync`, `verify` dispatch |
| `setup/features/catalog.lua` | Capability ID to handler mapping |
| `setup/features/<name>/` | Feature lifecycle implementation |
| `setup/host/` | Reusable host primitives |
| `setup/platforms/` | Runtime-wide host detection, paths, base environment |
| `setup/app.lua` | Catalog composition and profile-derived dependencies |

## Capability graph

```text
foundation
├── fonts
├── node ───────────────┐
├── go ─────────────────┤ Neovim profile prerequisites
├── nvim <──────────────┘
└── tmux [linux,darwin]
```

| Capability | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | — | — | CLI versions | All |
| `fonts` | Host registration/cache | — | Host visibility | All |
| `node` | NVM default/environment | — | NVM and Node version | All |
| `go` | — | — | Go version | All |
| `nvim` | — | Locks and parsers | Startup, locks, profile behavior | All |
| `tmux` | Plugin checkout | — | Commits, server, theme | Linux/macOS |

## Graph validation

`runtime/graph.lua` rejects:

- duplicate IDs;
- unknown dependencies;
- dependency cycles;
- enabled capabilities that depend on unsupported capabilities;
- invalid capability fields.

`runtime/runner.lua` rejects:

- missing handler tables;
- unknown lifecycle names;
- non-function lifecycle handlers.

## Lifecycle phases

| Phase | Input state | Responsibility |
| --- | --- | --- |
| Chezmoi apply | Repository source | Render files; install checksum-pinned externals |
| `setup` | Applied target home | Configure host state not represented by archives |
| `sync` | Configured applications | Restore mutable plugin/package/parser state |
| `verify` | Complete target home | Assert versions and observable behavior |

Entry point:

```text
nvim -l ~/.local/share/lazyvim/run.lua setup|sync|verify
```

## Neovim profile

Source: `home/dot_config/nvim/lua/languages/profile.lua`.

| Field | Type | Purpose |
| --- | --- | --- |
| `id` | string | Stable contribution ID |
| `requires` | string[] | Host capabilities inserted before `nvim` |
| `lazyvim_extras` | string[] | Imports placed before custom plugin specs |
| `plugin_module` | string | Custom spec imported after base plugins |
| `mason_packages` | string[] | Packages required in `mason-lock.json` |
| `language_cases` | case[] | Parser and LSP attachment verification |
| `formatter_cases` | case[] | On-disk formatter verification |

Consumers:

| Consumer | Use |
| --- | --- |
| `lua/config/lazy.lua` | Build ordered lazy.nvim specs |
| `setup/features/nvim/profile.lua` | Validate profile and derive prerequisites |
| `setup/features/nvim/init.lua` | Verify locks and behavior |
| `setup/features/nvim/child.lua` | Execute named configured-editor operations |

## Feature backend rule

Use feature-local backends for feature-specific host behavior:

```text
features/fonts/linux.lua
features/fonts/darwin.lua
features/fonts/win32.lua
features/node/unix.lua
features/node/windows.lua
```

Use `host/` only for reusable primitives. Use `platforms/` only for runtime-wide
paths, detection, and base environment.

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup.
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Treat directory existence as supporting evidence, not final proof.
