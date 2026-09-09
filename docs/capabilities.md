# Workstation package and lifecycle reference

## Dependency direction

```text
apps/cli/run.lua
  -> workstation.app
      -> workstation.catalog -> package factories -> package-local host behavior
      -> workstation.core.materialize -> specifications + handlers
      -> workstation.core.graph + workstation.core.runner
  -> workstation.source (composition root of the provider registry)
      -> workstation.provision.chezmoi / .shell / packages.nvim.compose
      -> workstation.state (generations, lock, journal)
  -> workstation.provisioner -> chezmoi backend with an exact generation

core -X-> catalog/packages/providers/chezmoi/Neovim
```

`workstation.app` materializes the graph; `workstation.source` interprets
collected recipe envelopes through the explicitly registered providers and
builds the deterministic source plan shared by `diff`, `apply` and `plan`.
Bootstrap-owned pinned Neovim hosts Lua without user configuration; Neovim
lifecycle behavior is an ordinary package. `bin/workstation` is the sole
public entry point.

## Module boundaries

| Path under `workstation/` | Contract |
| --- | --- |
| `apps/cli/run.lua` | Engine command dispatch through the public launcher |
| `lua/workstation/catalog.lua` | Explicit ordered inventory; one registration per package |
| `lua/workstation/core/contract.lua` | Combined contribution validation |
| `lua/workstation/core/materialize.lua` | Invoke factories and split specifications from handlers |
| `lua/workstation/core/graph.lua` | Host selection, dependency validation, topological ordering |
| `lua/workstation/core/runner.lua` | Lifecycle dispatch |
| `lua/workstation/provision/recipes.lua` | Public pure recipe constructors (`provision.chezmoi`, `provision.shell`) |
| `lua/workstation/provision/chezmoi.lua` | Chezmoi provider: option validation, native name encoding, confined assets |
| `lua/workstation/provision/shell.lua` | Shared-shell fragment compositor with exact-block retirement |
| `lua/workstation/provision/policy.lua` | Engine-owned legacy tombstones (exact seventeen) |
| `lua/workstation/source.lua` | Provider registry, plan assembly, conflict detection, reconciliation |
| `lua/workstation/state.lua` | Immutable generations, fail-closed lock, private journal and fingerprints |
| `lua/workstation/changesets.lua` | Attributable change sets and generated-source Git-style patches |
| `packages/<name>/` | Combined capability metadata, recipes, lifecycle behavior and `files/` payload |
| `packages/nvim/compose.lua` | nvim-owned profile compositor (`nvim-profile` provider) |
| `lua/workstation/commands.lua` | Checked child processes |
| `lua/workstation/paths.lua` | Target paths and isolated writable roots |
| `lua/workstation/provision.lua` | Verified archive provisioning |
| `lua/workstation/platforms/` | Runtime-wide paths, detection, and base environment |
| `lua/workstation/app.lua` | Catalog composition and runner creation |

## Contribution contract

Each catalog entry is a side-effect-free factory. It returns one combined record:

```lua
local provision = require("workstation.provision.recipes")

return function(environment)
  return {
    id = "example",
    requires = { "foundation" },
    supported_hosts = { linux = true, darwin = true },
    contributes = {
      provision.chezmoi({
        target = ".config/example/tool.conf",
        kind = "file",
        asset = "files/.config/example/tool.conf",
      }),
      provision.shell({
        target = ".profile",
        fragment = { id = "example-env", order = 50, marker = "# managed: example", body = "export EXAMPLE=1" },
      }),
    },
    setup = function(context) end,
    sync = function(context) end,
    verify = function(context) end,
  }
end
```

Only `id`, `requires`, `supported_hosts`, `contributes`, `setup`, `sync`, and
`verify` are allowed. `contributes` is a dense array of
`{ provider = <id>, spec = <options> }` envelopes; the pure constructors copy
options and perform no I/O, target writes or registration. Core validates only
the generic envelope shape; each registered provider validates its own specs
and rejects unknown options. Kinds: `file`, `directory`, `symlink`, `modify`
(one whole inline body or package-relative asset - structured fragments are the
`provision.shell` compositor's input alone and are rejected here) and `remove`.
Native
attributes are `private`, `executable`, `exact` and `template`; conflicting or
unrepresentable combinations are rejected instead of pretending arbitrary POSIX
modes are encoded. File/modifier content is exactly one inline body or a
package-relative asset confined to the owner package (no symlink traversal).
The materializer copies metadata into graph specifications and indexes
lifecycle handlers by the same ID; it does not deep-merge records. Packages are
never discovered from the filesystem.

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
├── nvim [requires foundation+node+go; owns base/standard/Go profile intents]
└── tmux [linux,darwin]

nvim
└── typescript [requires node+nvim; owns its plugin module, profile intent and verification]
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
| `go` | Exact toolchain archive; go link recipe | — | Go version | Linux/WSL/macOS |
| `secrets` | Pinned op archive member; op env fragment | — | Managed 1Password CLI version; never account or vault state | All supported hosts |
| `nvim` | — | Locks and parsers | Startup, locks, mason coverage, base/standard/Go behavior | All |
| `typescript` | — | — | Own Mason expectations, plugin module and behavior/formatter cases through nvim leaf helpers | All |
| `tmux` | Plugin checkout; tmux config/theme/link recipes | — | Commits, server, theme | Linux/macOS |

## Validation

The contract and materializer reject missing or duplicate package identities,
non-factory catalog entries, invalid dependency or host-support values, unknown
contribution fields, non-function lifecycle handlers and malformed recipe
envelopes. Registered providers reject unknown options, unsafe targets
(absolute, traversing, engine-state overlap), conflicting attribute
combinations, unconfined assets and ambiguous modify inputs. The assembler
rejects duplicate exclusive targets, incompatible ancestor types/attributes,
removals overlapping ownership and exact directories encompassing other owners.
The old text listing only core-level rejections is superseded:

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
| `plan` | Source declarations and journal | Validate and preview attributable change sets, generated-source patches, target preconditions and unsupported reversals; mutate nothing |
| `diff` | Same desired-state generation as apply | Ensure backend, preview file changes only; no retirement/setup/sync/verify |
| `apply` | Validated plan | Retire owned real-account legacy service (never scratch), publish the immutable generation, apply through the backend, refresh Node pin/PATH, setup |
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

`packages.nvim` declares the base/standard/Go language intents as
`nvim-profile` recipes (validated and composed by the nvim-owned compositor
`packages/nvim/compose.lua`); language capabilities such as `typescript`
declare their own intents the same way. The compositor orders intents by an
explicit `order` key (Go, TypeScript, standard) with graph collection order as
the tie-breaker, validates the assembled list and emits ONE attributed chezmoi
recipe that serializes the deployed `.config/nvim/lua/languages/profile.lua`.
The deployed profile is plain runtime Lua; a tampered deployed copy can never
alter the graph or the desired source because composition is source-derived.
`nvim` requires `foundation`, `node` and `go` explicitly; `typescript` requires
`node` and `nvim`. Dependencies are never inferred from deployed profile state.

| Consumer | Use |
| --- | --- |
| `packages/nvim/files/.config/nvim/lua/config/lazy.lua` | Build ordered lazy.nvim specs (deployed payload) |
| `packages/nvim/profile.lua` | Validate entries, recipes and serialize the composed profile |
| `packages/nvim/compose.lua` | nvim-owned `nvim-profile` compositor |
| `packages/nvim/init.lua` | Locks, synchronization, own behavior verification |
| `packages/nvim/leaf.lua` | Headless child/module/case helpers shared with language capabilities |
| `packages/nvim/child.lua` | Configured-editor child operations |

## Pi resources

`pi-skills` verifies managed skill files and discovery through Pi's resource loader.
The community packages `pi-subagents` and `pi-web-access` install with exact
registry integrity; their JavaScript verifiers stay package-local.
`pi-ntfy-notifier` deploys from
`workstation/packages/pi-ntfy-notifier/files/.pi/agent/extensions/ntfy-notifier/`
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
