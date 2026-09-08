# Workstation package and lifecycle reference

## Dependency direction

```text
apps/cli/run.lua
  -> workstation.app
      -> workstation.catalog -> package factories -> package-local host behavior
      -> workstation.core.materialize -> specifications + handlers
      -> workstation.core.graph + workstation.core.runner

core -X-> catalog/packages/Neovim
```

`workstation.app` is the composition root. Pinned Neovim remains only the Phase 1 Lua launcher; Neovim lifecycle behavior is an ordinary package.

## Module boundaries

| Path under `home/dot_local/share/workstation/` | Contract |
| --- | --- |
| `apps/cli/run.lua` | `setup`, `sync`, `verify` CLI entry point |
| `lua/workstation/catalog.lua` | Explicit ordered inventory; one registration per package |
| `lua/workstation/core/contract.lua` | Combined contribution validation |
| `lua/workstation/core/materialize.lua` | Invoke factories and split specifications from handlers |
| `lua/workstation/core/graph.lua` | Host selection, dependency validation, topological ordering |
| `lua/workstation/core/runner.lua` | Lifecycle dispatch |
| `packages/<name>/` | Combined capability metadata and lifecycle behavior |
| `lua/workstation/host/` | Reusable host primitives |
| `lua/workstation/platforms/` | Runtime-wide paths, detection, and base environment |
| `lua/workstation/app.lua` | Catalog composition and runner creation |

## Contribution contract

Each catalog entry is a side-effect-free factory. It returns one combined record:

```lua
return function(environment)
  return {
    id = "example",
    requires = { "foundation" },
    supported_hosts = { linux = true, darwin = true },
    setup = function(context) end,
    sync = function(context) end,
    verify = function(context) end,
  }
end
```

Only `id`, `requires`, `supported_hosts`, `setup`, `sync`, and `verify` are allowed. Lifecycle fields are optional functions. The materializer copies metadata into graph specifications and indexes lifecycle handlers by the same ID; it does not deep-merge records. Packages are never discovered from the filesystem.

## Package graph

```text
foundation
├── fonts
├── node
│   └── pi
│       ├── pi-skills
│       │   └── pi-subagents
│       └── pi-web-access
├── go [Neovim language toolchain]
├── secrets
├── nvim [package factory adds profile prerequisites]
└── tmux [linux,darwin]
```

| Package | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | — | — | CLI versions | All |
| `fonts` | Host registration/cache | — | Host visibility | All |
| `node` | NVM default/environment | — | NVM and Node version | All |
| `pi` | Exact global npm package | — | npm package and CLI version | All |
| `pi-skills` | — | — | Managed skill files and Pi discovery | All |
| `pi-subagents` | Exact Pi package and role skill policy | — | Lock integrity, extension tools, skill, role overrides | All |
| `pi-web-access` | Exact Pi package | — | Lock integrity, extension discovery, web tools | All |
| `go` | — | — | Go version | Linux/WSL/macOS |
| `secrets` | — | — | Managed 1Password CLI version; never account or vault state | All supported hosts |
| `nvim` | — | Locks and parsers | Startup, locks, profile behavior | All |
| `tmux` | Plugin checkout | — | Commits, server, theme | Linux/macOS |

## Validation

The contract and materializer reject:

- missing or duplicate package identities;
- non-factory catalog entries;
- invalid dependency or host-support values;
- unknown contribution fields;
- non-function lifecycle handlers.

The graph rejects duplicate IDs, unknown dependencies, dependency cycles, and enabled packages that require unsupported packages. The runner rejects missing handler tables and unknown lifecycle names.

## Lifecycle phases

| Phase | Input state | Responsibility |
| --- | --- | --- |
| Chezmoi apply | Repository source | Render files and install checksum-pinned externals |
| `setup` | Applied target home | Configure host state not represented by archives |
| `sync` | Configured applications | Restore mutable application state |
| `verify` | Complete target home | Assert versions and observable behavior |

Entry point:

```text
nvim -l ~/.local/share/workstation/apps/cli/run.lua setup|sync|verify
```

## Neovim package and profile

The `packages.nvim` factory loads and validates the sole language profile source at `home/dot_config/nvim/lua/languages/profile.lua`. It adds profile `requires` values to its package dependencies and closes over the profile for sync and verification. Generic app and core modules do not import Neovim.

| Consumer | Use |
| --- | --- |
| `home/dot_config/nvim/lua/config/lazy.lua` | Build ordered lazy.nvim specs |
| `packages/nvim/profile.lua` | Validate profile and derive prerequisites |
| `packages/nvim/init.lua` | Locks, synchronization, behavior verification |
| `packages/nvim/child.lua` | Configured-editor child operations |

## Pi resources

`pi-skills` verifies managed files under `home/dot_pi/private_agent/skills/` and Pi discovery. The pinned community packages `pi-subagents` and `pi-web-access` are installed through their owning packages with exact registry integrity. Package-specific JavaScript verifiers remain inside their owning package directories.

## Package-local backend rule

Feature-specific host branches remain under the package:

```text
packages/fonts/linux.lua
packages/fonts/darwin.lua
packages/node/unix.lua
```

Use `host/` only for reusable primitives and `platforms/` only for runtime-wide detection, paths, and environment.

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup.
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Treat directory existence as supporting evidence, not final proof.
