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

`workstation.app` is the composition root. Bootstrap-owned pinned Neovim hosts Lua without user configuration; Neovim lifecycle behavior is an ordinary package. `bin/workstation` is the sole public entry point.

## Module boundaries

| Path under `workstation/` | Contract |
| --- | --- |
| `apps/cli/run.lua` | Engine command dispatch through the public launcher |
| `lua/workstation/catalog.lua` | Explicit ordered inventory; one registration per package |
| `lua/workstation/core/contract.lua` | Combined contribution validation |
| `lua/workstation/core/materialize.lua` | Invoke factories and split specifications from handlers |
| `lua/workstation/core/graph.lua` | Host selection, dependency validation, topological ordering |
| `lua/workstation/core/runner.lua` | Lifecycle dispatch |
| `packages/<name>/` | Combined capability metadata and lifecycle behavior |
| `lua/workstation/commands.lua` | Checked child processes |
| `lua/workstation/paths.lua` | Target paths and isolated writable roots |
| `lua/workstation/provision.lua` | Verified archive provisioning |
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
│       ├── pi-web-access
│       └── pi-ntfy-notifier [source-managed]
├── go [Neovim language toolchain]
├── secrets
├── nvim [package factory adds profile prerequisites]
└── tmux [linux,darwin]
```

| Package | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | CLI archive members | — | CLI versions | All |
| `fonts` | Font archives, then host registration/cache | — | Host visibility | All |
| `node` | nvm and Node archives, then default/environment | — | NVM and Node version | All |
| `pi` | Exact global npm package | — | npm package and CLI version | All |
| `pi-skills` | — | — | Managed skill files and Pi discovery | All |
| `pi-subagents` | Exact Pi package and role skill policy | — | Lock integrity, extension tools, skill, role overrides | All |
| `pi-web-access` | Exact Pi package | — | Lock integrity, extension discovery, web tools | All |
| `pi-ntfy-notifier` | Source-managed extension | — | Manifest version, extension files, node test suite | All |
| `go` | Exact toolchain archive | — | Go version | Linux/WSL/macOS |
| `secrets` | Pinned op archive member | — | Managed 1Password CLI version; never account or vault state | All supported hosts |
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
| `bootstrap` | Whole source checkout, shell prerequisites | Install verified pinned runtime/backend, then conflict-safe public launcher |
| `apply` | Repository source | Retire owned real-account legacy service (never scratch), materialize files, refresh Node pin/PATH, setup |
| `setup` | Applied target home | Provision package archives and configure host state; reject missing Node pin before Node/nvm provisioning |
| `sync` | Configured applications | Restore mutable application state |
| `verify` | Complete target home | Assert versions and observable behavior |
| `diff` | Source and target | Ensure backend, preview file changes only |
| `update` | Git clone | Checked pull --ff-only, fresh launcher bootstrap, apply, sync, verify; stop at first failure |

Bootstrap retains an identical canonical launcher symlink, refuses conflicting
paths and never reports completion after a backend failure. Update re-executes
the newly pulled launcher before each lifecycle step, including bootstrap so pin
changes take effect. See [installation and daily use](../README.md).

## Neovim package and profile

The `packages.nvim` factory uses an explicitly supplied `environment.nvim_profile`
or loads the target home's `.config/nvim/lua/languages/profile.lua`, falling back
to the repository copy only when the target file is absent. The canonical editable
source is `chezmoi/dot_config/nvim/lua/languages/profile.lua`; editing it does not
immediately change an already-applied home's graph. The loader validates the
[profile fields](nvim.md#profile-fields); the factory adds their `requires` values
to package dependencies and closes over the profile for sync/verify. Generic app
and core modules do not import Neovim.

| Consumer | Use |
| --- | --- |
| `chezmoi/dot_config/nvim/lua/config/lazy.lua` | Build ordered lazy.nvim specs |
| `packages/nvim/profile.lua` | Validate profile and derive prerequisites |
| `packages/nvim/init.lua` | Locks, synchronization, behavior verification |
| `packages/nvim/child.lua` | Configured-editor child operations |

## Pi resources

`pi-skills` verifies managed skill files and discovery through Pi's resource loader.
The community packages `pi-subagents` and `pi-web-access` install with exact
registry integrity; their JavaScript verifiers stay package-local.
`pi-ntfy-notifier` deploys from `chezmoi/dot_pi/private_agent/extensions/ntfy-notifier/`
through `workstation apply`, followed by Pi `/reload` or a new process.

Notifier package verification checks manifest/version/files and Node unit tests
that import the extension with a mock Pi API. These do **not** prove actual Pi
auto-discovery or reload cleanup. Real discovery and reload acceptance remains a
separate required check for extension changes: confirm commands/events load once
and shutdown/reload releases owned resources without duplicate handlers. Keep
checks independent of credentials; live notification delivery requires separate
authorization and must not expose tokens.

## Package-local backend rule

Feature-specific host branches remain under the package:

```text
packages/fonts/linux.lua
packages/fonts/darwin.lua
packages/node/unix.lua
```

Reuse `lua/workstation/commands.lua`, `lua/workstation/paths.lua` and
`lua/workstation/provision.lua` for checked children, target paths and archive
provisioning. Use `lua/workstation/platforms/` only for runtime-wide detection,
paths and environment (paths relative to `workstation/`).

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup.
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Treat directory existence as supporting evidence, not final proof.
