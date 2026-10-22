# LazyVim workstation

Nix-substrate workstation for pinned Neovim, tmux configuration and Pi
resources on Linux x86_64 (including WSL-as-Linux) and macOS arm64.
Nix owns the lifecycle — build, pins, the file plane, activation and
rollback; the `workstation` engine is the resident read surface (status,
plan, capabilities, the TUI dashboard) and the daemon that serves reads and
publishes generation-switch events.

## Prerequisites

- Nix with flakes enabled. The hosts under [`hosts/`](hosts/) declare
  everything else: per-host identity lives only in
  `hosts/<host>/default.nix`, and the flake's package set builds the engine
  release and every pinned tool in the store.
- The legs: `hosts/wsl` (NixOS-WSL), `hosts/omarchy` (standalone
  home-manager on Arch, `homeConfigurations`), `hosts/mac` (nix-darwin,
  `darwinConfigurations`; brew reduced to casks). A NixOS VM boot test
  (`tests/nix`) proves the daemon user unit and the switch seam.
- Git for the checkout; on a checkout host (no nix), mise resolves the
  repo-pinned Erlang/Elixir toolchain (`.tool-versions`) to build the
  release.

## Hosts

Switch a host through the substrate — the leg-native rebuild, or the
`workstation-switch` driver (baked into each generation; it wraps the
leg-native switch and publishes the receipt to the running daemon):

```sh
home-manager switch --flake .#omarchy        # Arch leg (standalone HM)
sudo nixos-rebuild switch --flake .#wsl      # NixOS-WSL leg
darwin-rebuild switch --flake .#mac          # macOS leg (nix-darwin)

workstation-switch apply            # leg-native switch + the receipt publish
workstation-switch rollback         # atomic rollback to the prior generation
```

Every switch ends with the receipt publish on the `system` overlay domain;
read it through the engine:

```sh
workstation system applied                 # the current generation receipt
workstation system applied --generation 7  # inspect a past switch
```

## The engine

The engine is an Elixir OTP release (`nix/engine.nix`, `mixRelease`) plus
the package tree under `workstation/packages/` — self-contained package
dirs (manifest beside payloads) that BOTH readers consume as data: the nix
walker (`nix/manifest-lib.nix`) renders them into the HM/NixOS
declarations, and the engine's native catalog composes the desired state
for its reads. The walker report is drift-guarded against the recorded
goldens (`sh .github/scripts/eval-goldens.sh`; CI runs it on Linux).

```sh
workstation          # TUI dashboard: engine / capabilities / plan / status
workstation plan     # the composed desired state; mutates nothing
workstation status   # paths, the explicit package graph, the catalog taxonomy
workstation capabilities  # capability-domain rollups with per-package drill-down
workstation json status | plan  # the raw wire reports
```

On a usable terminal the bare verb opens the TUI dashboard: digits 1-4
toggle boxes, `p`/`P` cycle presets, `?` is the help overlay, `q` quits.
Without a TTY the bare verb prints the verb help instead of hanging
(exit 0, no TUI start); scripts pass `--headless` to the read verbs — a
non-interactive run WITHOUT the flag hard-errors instead of degrading
silently.

### Client/daemon model

Every verb speaks to the workstation **daemon** — a per-user background
process serving reads and pubsub (“`iex` to a running node”). The first
verb resolves the daemon's Unix socket; when absent or dead the client
spawns a daemon detached from the installed release and waits (bounded)
for its handshake. There is no in-process fallback: a daemon that cannot
start is a clear error. `workstation daemon stop` retires it manually.
On NixOS the daemon runs as the `workstation-daemon` user unit (the VM
test pins it); generation switches publish on the `system` overlay domain
and any subscribed client sees them live.

The copy contract and the hot-home law survive: home-manager never manages
`~/.hermes`; hot directories carry declared copy payloads (inert data), so
a running program's writes never fight the substrate.

## Checkout-host builds (no nix)

The launcher `workstation/bin/workstation` is plain POSIX sh: it anchors
the checkout (`WORKSTATION_ENGINE_REPO`), brackets the state roots, guards
the UTF-8 locale, and execs the placed release
(`~/.local/opt/workstation/bin/workstation`). On a checkout host, build and
stage the release yourself:

```sh
mise exec -- env MIX_ENV=prod mix release workstation --overwrite
```

The engine reads the package tree from the checkout; the reads never
mutate a home.

## Secrets and ownership

No login profiles, secret values, provider credentials, 1Password account
sessions, or vault state belong to the engine. The source-managed ntfy
notifier and pinned Pi packages retain their own discovery/reload
contracts; see the references below.

## Documentation and validation

| Reference | Scope |
| --- | --- |
| [`docs/index.md`](docs/index.md) | Repository navigation |
| [`docs/testing.md`](docs/testing.md) | Fast checks, isolated E2E and acceptance limits |
| [`docs/capabilities.md`](docs/capabilities.md) | Capability boundaries and lifecycle |
| [`docs/chezmoi.md`](docs/chezmoi.md) | Home state law (native declarations) and the cutover history |
| [`docs/tools.md`](docs/tools.md) | Managed inventory and prerequisites |
| [`docs/secrets.md`](docs/secrets.md) | User-owned authentication and explicit secrets skill |
| [`docs/nvim.md`](docs/nvim.md), [`docs/tmux.md`](docs/tmux.md) | Application configuration |
| [`docs/elixir.md`](docs/elixir.md) | Engine architecture, CLI/TUI contract, taxonomy, migration history |
| `AGENTS.md` | Contributor rules |

Run `sh .github/scripts/check.sh` for safe isolated source checks (golden
contract, nix eval-goldens, identity gate, engine suite, doclint, shell
checks); never run fixtures directly against a switched home. Real nix
builds and VM boots require explicit authorization; follow
[testing](docs/testing.md), not a live-home experiment. CI uses Linux and
macOS arm64 runners; WSL follows Linux. Release CI validates before
producing tagged source archives and SHA-256 sums, not a separate engine
build or installer.
