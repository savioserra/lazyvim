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
│   └── subagents [also requires pi; active owner daemon, actor client, and hosted bridge]
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
| `go` | — | — | Go version | Linux/WSL/macOS policy; legacy Windows removal inventory remains |
| `subagents` | Exact actor extension runtimes, daemon/client build, owner service activation | — | Owner-private active config, binary paths, extension discovery, lock integrity | Linux/WSL/macOS |
| `secrets` | — | — | Managed 1Password CLI version; never account or vault state | All; Windows ARM64 uses x64 emulation |
| `nvim` | — | Locks and parsers | Startup, locks, profile behavior | All |
| `tmux` | Plugin checkout | — | Commits, server, theme | Linux/macOS |
| `pi-tmux-subagents` | Locked XState/Terminal Kit install | — | Supervised actor extension, companion skill, exact RPC/dependency gate, launcher | Linux/macOS |

## GoAkt subagents boundary

`packages/subagents/` owns the active owner-private deployed configuration, source-managed actor client, hosted bridge dependencies, daemon/client builds, and user-service activation. Setup installs exact npm dependencies from local locks, builds `workstation-subagents` and `workstation-subagents-clientctl` from the sole nested module `services/subagents/`, and enables/starts the owner systemd-user service or LaunchAgent. The managed TOML requires service and hosted Pi enabled, remoting disabled, and renders as `~/.config/workstation/subagents/config.toml` under 0700 directories with mode 0600.

The long-lived service has one global `ServiceGuardian`. Its `AgentRegistryActor` owns stable reusable AgentActors independently of the sibling `SessionRegistryActor`. Client sessions are ephemeral access/subscription contexts; cleanup leaves AgentActors and hosted runtimes intact. Explicit hosted-owned agents own one `HostedPiRuntimeActor` child with asynchronous typed effects, lifecycle states, and DeathWatch. The concrete runtime records and revalidates exact tmux session/window/pane/PID/start-token/TTY identity and writes bounded atomic owner-private XDG operational records. Startup securely adopts only exact live owned tmux/Pi identity, restores fenced mutation/delivery state, and fails closed for foreign or indeterminate records. Existing observed-upstream agents and XState authority remain unchanged.

The application protocol is bounded, sequenced protobuf-framed WebSocket traffic for ordinary clients and the hosted bridge and remains separate from optional GoAkt cluster remoting. Schema-v2 remoting validates a concrete local trusted-network bind, configured peer names, distinct fixed cluster ports, logical identities, and owner-private URI-SAN mTLS material; DNS supplies addresses only and is never identity. The operator-provided private network boundary and mTLS independently restrict the actor plane. Validated enabled configuration installs `actor.WithRemote`, `actor.WithCluster`, and `actor.WithoutRelocation`; managed configuration remains disabled until host certificates and physical multi-node validation exist.

See [`subagents.md`](subagents.md) for paths, platform inventory, fixtures, and commands.

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

`pi-skills` verifies managed files under `home/dot_pi/private_agent/skills/` and Pi discovery. The workstation actor package owns the globally discoverable env-free `actor-client`, hosted-only `hosted-pi-bridge`, generated protobuf copies, exact dependency locks, and discovery checks. Legacy third-party `pi-subagents` and `tmux-subagents` wiring is not part of the workstation actor authority. Package-specific JavaScript verifiers remain inside their owning package directories.

## Workstation actor UI

The workstation actor extension is the single user-facing actor UI. It registers `/actor-*` commands and `actor_*` tools, including `/actor-connect <node|host|ws://host:port/actors>` for explicitly selecting another advertised workstation endpoint. Hosted tmux panes are owned by the workstation runtime and remain ordinary Pi TUIs; no legacy observer extension or third-party run authority is required.

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
