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
not Node, Python, jq, system Neovim, LuaJIT or a preinstalled chezmoi. The
engine itself is a checksummed Elixir OTP release: a fresh bootstrap builds it
from the checkout when a `mise` Erlang/Elixir toolchain is available, and the
installed release thereafter manages its own re-acquisition (`workstation
bootstrap` refreshes it after `pull`). Managed tools and their exact pins are
listed in [`docs/tools.md`](docs/tools.md).

## Fresh installation

**Stop if `~/.local/share/workstation` already exists.** It may be the old deployed
engine payload, not a Git clone. Follow the guarded [cutover procedure](docs/chezmoi.md#breaking-cutover)
with the operator; never clone over or erase it.

One-line bootstrap — the installer performs exactly the guarded sequence below and
enforces the same stop rule (audit it first with `curl -fsSL <url> -o install.sh && sh install.sh`;
overrides: `WORKSTATION_REPO`, `WORKSTATION_REF`, `WORKSTATION_DEST`):

```sh
curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh | sh
```

Or manually:
git clone https://github.com/savioserra/lazyvim.git "$HOME/.local/share/workstation"
"$HOME/.local/share/workstation/workstation/bin/workstation" bootstrap
"$HOME/.local/bin/workstation" apply
"$HOME/.local/bin/workstation" sync
"$HOME/.local/bin/workstation" verify
```

The clone is the **whole repository**; every home-state payload and recipe
lives with its owning package under `workstation/packages/`, and the engine —
an Elixir OTP release built from the checkout — generates target-specific
chezmoi source at apply time; there is no checked-in centralized payload tree
and no Lua or nvim execution in the engine path. Any checkout can host the
launcher. Bootstrap prepares the checksum-pinned Neovim runtime and chezmoi
backend (managed capabilities), builds/installs the engine release, then
atomically creates
`~/.local/bin/workstation` pointing to that checkout's actual repo-native launcher.
A matching link is retained; conflicting user files/links/directories are refused,
not replaced. Keep the checkout available. Add `~/.local/bin` to your PATH for the
commands below (managed shell files also do this for future shells).

## Daily lifecycle

```sh
workstation plan     # attributable change-set/patch preview; mutates nothing
workstation diff     # preview file-backend changes (not a setup simulation)
workstation apply    # guarded legacy retirement, files, then package setup
workstation sync     # separately restore mutable application state
workstation verify   # check installed versions and behavior
workstation update   # git pull --ff-only, fresh bootstrap, apply, sync, verify
workstation status   # inspect paths, the explicit package graph and the catalog taxonomy
```

Interactive verbs (`apply`, `update`) render the terminal UI when stdout is
a usable terminal. Scripts and CI pass `--headless` to run the plain
executor; a non-interactive run WITHOUT the flag hard-errors instead of
degrading silently.

### Client/daemon model

Every verb speaks to the workstation **daemon** — a per-user background
process that is the only mutation engine and the only source of live state
(“`iex` to a running node”). The first verb resolves the daemon's Unix
socket; when absent or dead the client spawns a daemon detached from the
installed release and waits (bounded) for its handshake. There is no
in-process fallback: a daemon that cannot start is a clear error, since
the apply lock must have exactly one owner. `workstation daemon stop`
retires it manually; no OS service manager is involved.

Long verbs stream their progress live: headless runs render the familiar
`[1/5] pull ok` lines from the daemon's event stream, the TUI transitions
rows on the same events, and `update` survives its own release refresh —
the daemon hands off across the rebuild and the client re-spawns it, so
one banner, one chain, one exit code. Interactive screens accept `x` to
abort at the next step boundary (`q` merely detaches; the daemon keeps
running). The daemon also watches passively: `status` reports an
`update_available` verdict, and the TUI shows `↑ update available … — [u]
update` only when the install branch is behind its origin — silence means
up to date or unknown.

Update invokes the freshly pulled launcher for **bootstrap before apply**, so new
runtime/backend/release pins are installed. Every child is checked; the first failure
stops subsequent phases. Bootstrap/backend failure never reports readiness.
`apply` refreshes the materialized Node pin and PATH before setup. Direct `setup`
before first apply rejects a missing/invalid `.node-version` before nvm/Node
provisioning; it is not the fresh-install entry point. There are no compatibility
aliases or `workstation apply --dry-run`; use `diff` or an isolated file render.

No login profiles, secret values, provider credentials, 1Password account sessions,
or vault state belong to the engine. The source-managed ntfy notifier and pinned
Pi packages retain their own discovery/reload contracts; see the references below.

## Documentation and validation

| Reference | Scope |
| --- | --- |
| [`docs/index.md`](docs/index.md) | Repository navigation |
| [`docs/testing.md`](docs/testing.md) | Fast checks, isolated E2E and acceptance limits |
| [`docs/capabilities.md`](docs/capabilities.md) | Package boundaries and lifecycle |
| [`docs/chezmoi.md`](docs/chezmoi.md) | File backend, scratch rendering, guarded cutover |
| [`docs/tools.md`](docs/tools.md) | Managed inventory and prerequisites |
| [`docs/secrets.md`](docs/secrets.md) | User-owned authentication and explicit secrets skill |
| [`docs/nvim.md`](docs/nvim.md), [`docs/tmux.md`](docs/tmux.md) | Application configuration |
| [`docs/elixir.md`](docs/elixir.md) | Engine architecture, CLI/TUI contract, taxonomy, migration history |
| `AGENTS.md` | Contributor rules |

Run `sh .github/scripts/check.sh` for safe isolated source checks; never run
fixtures directly against an applied home. Real scratch integration downloads
assets and requires explicit authorization; follow [testing](docs/testing.md),
not a live-home experiment. CI uses Linux and macOS arm64 runners; WSL follows
Linux. Release CI validates before producing tagged source archives and SHA-256
sums, not a separate engine build or installer.
