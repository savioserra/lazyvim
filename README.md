# LazyVim workstation

Repo-native workstation engine for pinned Neovim, tmux configuration and Pi
resources on Linux x86_64 (including WSL-as-Linux) and macOS arm64.
`workstation` owns the lifecycle; chezmoi is its subordinate home-file backend.

## Prerequisites

The user or CI image supplies these; workstation never runs an OS package manager:

- Git; tmux >=3.2; Bash >=5.2 for tmux2k.
- POSIX shell, HTTPS curl, tar/gzip, unzip, SHA-256 tools (`sha256sum` on Linux,
  `shasum` on macOS), and ordinary Unix filesystem tools.
- C compiler/build tools for parser and application-package builds (macOS Command
  Line Tools); Linux fontconfig (`fc-cache`, `fc-list`). macOS supplies
  `system_profiler` for font verification.

Bootstrap itself needs only the shell/download/archive/hash/filesystem essentials,
not Node, Python, jq, system Neovim, LuaJIT or a preinstalled chezmoi.
Managed tools and their exact pins are listed in [`docs/tools.md`](docs/tools.md).

## Fresh installation

**Stop if `~/.local/share/workstation` already exists.** It may be the old deployed
engine payload, not a Git clone. Follow the guarded [cutover procedure](docs/chezmoi.md#breaking-cutover)
with the operator; never clone over or erase it.

```sh
git clone https://github.com/savioserra/lazyvim.git "$HOME/.local/share/workstation"
"$HOME/.local/share/workstation/workstation/bin/workstation" bootstrap
"$HOME/.local/bin/workstation" apply
"$HOME/.local/bin/workstation" sync
"$HOME/.local/bin/workstation" verify
```

The clone is the **whole repository**, containing sibling `workstation/` and
`chezmoi/` directories. Any checkout can host the launcher. Bootstrap prepares the
checksum-pinned Neovim runtime and chezmoi backend, then atomically creates
`~/.local/bin/workstation` pointing to that checkout's actual repo-native launcher.
A matching link is retained; conflicting user files/links/directories are refused,
not replaced. Keep the checkout available. Add `~/.local/bin` to your PATH for the
commands below (managed shell files also do this for future shells).

## Daily lifecycle

```sh
workstation diff     # preview file-backend changes (not a setup simulation)
workstation apply    # guarded legacy retirement, files, then package setup
workstation sync     # separately restore mutable application state
workstation verify   # check installed versions and behavior
workstation update   # git pull --ff-only, fresh bootstrap, apply, sync, verify
workstation status   # inspect paths and the explicit package graph
```

Update invokes the freshly pulled launcher for **bootstrap before apply**, so new
runtime/backend pins are installed. Every child is checked; the first failure
stops subsequent phases. Bootstrap/backend failure never reports readiness.
`apply` refreshes the materialized Node pin and PATH before setup. Direct `setup`
before first apply rejects a missing/invalid `.node-version` before nvm/Node
provisioning; it is not the fresh-install entry point. There are no compatibility
aliases or `workstation apply --dry-run`; use `diff` or an isolated file render.

No login profiles, secret values, provider credentials, 1Password account sessions,
or vault state belong to the engine. The source-managed ntfy notifier and pinned
Pi packages retain their own discovery/reload contracts; see the references below.

## Sources of truth

| State | Owner |
| --- | --- |
| Engine runtime/backend and host download metadata | `workstation/versions.json`; generated bootstrap pin projection |
| Host provisioning | `workstation/packages/` setup; Neovim/backend bootstrap |
| Node version | `chezmoi/dot_node-version` only |
| Managed home configuration | `chezmoi/` (no externals or lifecycle scripts) |
| Package ordering / generic core | `workstation/lua/workstation/catalog.lua` / `core/` |
| Neovim plugins / Mason tools | `chezmoi/dot_config/nvim/lazy-lock.json` / `mason-lock.json` |
| Language composition / parsers | `chezmoi/dot_config/nvim/lua/languages/profile.lua` / parser config and locked plugin |
| Pi skills / source-managed extensions | `chezmoi/dot_pi/private_agent/skills/` / `extensions/` |
| Registry Pi packages | Exact versions/integrity in `workstation/versions.json`, owning package verification |
| tmux plugin commits | `workstation/packages/tmux/init.lua` |

Update version, owning URL/checksum or registry integrity, verification and tool
documentation together. Never edit deployed state to change the source contract.

## Documentation and validation

| Reference | Scope |
| --- | --- |
| [`docs/index.md`](docs/index.md) | Repository map and checks |
| [`docs/capabilities.md`](docs/capabilities.md) | Package boundaries and lifecycle |
| [`docs/chezmoi.md`](docs/chezmoi.md) | File backend, scratch rendering, guarded cutover |
| [`docs/tools.md`](docs/tools.md) | Managed inventory and prerequisites |
| [`docs/secrets.md`](docs/secrets.md) | User-owned authentication and explicit secrets skill |
| [`docs/nvim.md`](docs/nvim.md), [`docs/tmux.md`](docs/tmux.md) | Application configuration |
| [`docs/lua-migration.md`](docs/lua-migration.md) | Runtime rationale and historical context |
| `AGENTS.md` | Contributor rules |

`.github/scripts/test-apply.sh /absolute/new/scratch-home` drives real
bootstrap → apply → sync → all fast checks/format → verify. The destination must
not exist, must be outside the real home/source, and is retained even on failure.
The harness clears ambient environment and confines HOME/XDG/cache/temp without
loading login profiles or `/etc` auth snippets. It downloads real managed assets;
offline fixture tests are a separate gate, not full lifecycle acceptance.
StyLua comes from the locked Mason profile after sync. CI uses Linux and macOS
arm64 runners; WSL follows Linux. Release CI validates before producing tagged
source archives and SHA-256 sums, not a separate engine build or installer.
