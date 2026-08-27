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
│       └── pi-skills
│           └── pi-subagents
├── go
├── secrets
├── nvim [package factory adds profile prerequisites]
└── tmux [linux,darwin]
    └── pi-tmux-subagents [also requires pi-subagents]
```

| Package | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | — | — | CLI versions | All |
| `fonts` | Host registration/cache | — | Host visibility | All |
| `node` | NVM default/environment | — | NVM and Node version | All |
| `pi` | Exact global npm package | — | npm package and CLI version | All |
| `pi-skills` | — | — | Managed skill files and Pi discovery | All |
| `pi-subagents` | Exact Pi package and role skill policy | — | Lock integrity, extension tools, skill, role overrides | All |
| `go` | — | — | Go version | All |
| `secrets` | — | — | Managed 1Password CLI version; never account or vault state | All; Windows ARM64 uses x64 emulation |
| `nvim` | — | Locks and parsers | Startup, locks, profile behavior | All |
| `tmux` | Plugin checkout | — | Commits, server, theme | Linux/macOS |
| `pi-tmux-subagents` | Locked XState/Terminal Kit install | — | Supervised actor extension, companion skill, exact RPC/dependency gate, launcher | Linux/macOS |

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

`pi-skills` verifies managed files under `home/dot_pi/agent/skills/` and Pi discovery. `pi-subagents` owns its exact package installation, lock integrity, extension discovery, bundled skill, and `lazyvim` role-skill assignment. `pi-tmux-subagents` owns the source-managed XState actor extension, exact local npm lock, Terminal Kit renderer process, companion skill, launcher, and Pi discovery checks. Package-specific JavaScript verifiers remain inside their owning package directories.

## Tmux subagent observer

`pi-subagents` remains authoritative for execution, sessions, worktrees, recovery, receipts, steer, stop, and resume. The `tmux-subagents` extension uses the documented process-local `subagents:rpc:v1` `ping` and `status` methods and locally validates the bounded version-1 async snapshot. It does not import the sibling package or read arbitrary run artifact paths.

Prepared panes cooperate by running the launcher in the foreground with the exact attested Node and renderer paths. Every owner-only generation directory contains a one-use ticket bound to the Pi session/generation, one visible managed run and optional child, rotating reconnect credential, expiry, generation-private socket, and bounded projection. Created-pane tickets additionally carry the exact expected tmux socket, stable pane ID, pane PID/TTY, and session ID; adopted-pane identity is recorded only from its cooperative claim. Symlinks, foreign ownership, path escapes, permission widening, duplicate claims, and stale generations fail closed. Focus and kill use one conditional tmux server command queue over the full tuple. Adopted panes are never sent keys, respawned, or killed. Closing or losing any pane affects the view only.

The extension gate remains disabled until reviewed deployment. Production accepts only the canonical managed config and its apply-produced activation digest. Setup installs `xstate@5.32.6` and `terminal-kit@3.1.4` from the exact local package lock using `npm ci --omit=dev --ignore-scripts`; verification checks lock integrity, installed manifests, regular ownership, and absence of native `.node` modules. The root actor owns authority refresh/control and run mirrors; the production-effects supervisor owns renderer IPC, serialized topology operations, projection publication, and one exact pane/authenticated-IPC lifecycle child per view with OTP-style restart intensity, backoff, and circuit-open receipts. Adopted view children are temporary observers and can never recreate or mutate their pane. Only documented `pi-subagents` RPC can change authoritative state. The standalone renderer uses rotating authentication, one active connection per binding, aggregate rate limits, and bounded sequenced NDJSON. Apply and `/reload` remain separate boundaries; fail-closed smoke proves acknowledged isolated steer, Terminal Kit rendering, real renderer-process restart, stale-generation rejection, created-pane absence after detach, exact foreign-pane tuple preservation, and unchanged real managed-run state.

## Package-local backend rule

Feature-specific host branches remain under the package:

```text
packages/fonts/linux.lua
packages/fonts/darwin.lua
packages/fonts/win32.lua
packages/node/unix.lua
packages/node/windows.lua
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
