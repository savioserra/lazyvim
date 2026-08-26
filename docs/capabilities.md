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
├── node
│   └── pi
│       └── pi-skills
│           └── pi-subagents
├── go
├── secrets
├── nvim [profile adds node and go prerequisites]
└── tmux [linux,darwin]
```

| Capability | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | — | — | CLI versions | All |
| `fonts` | Host registration/cache | — | Host visibility | All |
| `node` | NVM default/environment | — | NVM and Node version | All |
| `pi` | Exact global npm package | — | npm package and CLI version | All |
| `pi-skills` | — | — | Managed skill files and Pi discovery | All |
| `pi-subagents` | Exact Pi package and role skill policy | — | Package lock integrity, extension tools, bundled skill, role overrides | All |
| `go` | — | — | Go version | All |
| `secrets` | — | — | Managed 1Password CLI version; never account or vault state | All; Windows ARM64 uses x64 emulation |
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

## Pi skills

| Item | Value |
| --- | --- |
| Source | `home/dot_pi/agent/skills/<name>/SKILL.md` |
| Target | `~/.pi/agent/skills/<name>/SKILL.md` |
| Owner capability | `pi-skills` |
| Discovery | Pi `DefaultResourceLoader` using the managed agent directory |

Each skill requires valid `name` and `description` frontmatter. Add the skill to
`setup/features/pi-skills.lua` so verification checks both the managed file and
Pi's resource discovery. The `secrets` skill disables model invocation and is
available only through explicit `/skill:secrets` use.

## Pi subagents

| Item | Value |
| --- | --- |
| Package | `pi-subagents@0.56.0` |
| Source | npm package from `nicobailon/pi-subagents` |
| Pi package target | `~/.pi/agent/npm/node_modules/pi-subagents` |
| Package declaration | Preserved alongside user preferences in `~/.pi/agent/settings.json` |
| Workstation policy | `worker` and `delegate` explicitly receive the managed `lazyvim` skill |

The package is exact-version and registry-integrity verified before installation.
Verification checks Pi discovery, the `subagent` and `subagent_wait` tools, the
bundled `pi-subagents` skill, package-lock integrity, and role overrides. The
`lazyvim` skill asks mutation-capable agents to use tmux only for suitable
long-running, interactive, or observable work and to prefer this setup's managed
tools and chezmoi lifecycle.

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
