# workstation

Every machine you own — a linux box, a WSL host, a mac — carrying the same
tools, switched by one command and rolled back by another.

The whole workstation is nix declarations: the shell and prompt, Neovim
(LazyVim) with per-language setups, tmux, fonts, the CLI toolset, secrets
wiring, and an agent fleet whose members call each other over tailscale.
One nixpkgs input decides every version. Nothing is installed by hand,
nothing drifts between machines.

Why:

- **One command per machine.** `workstation init` captures a machine,
  `workstation apply` switches it to what `main` builds. Updates are
  atomic with rollback; a switch that changes nothing deployed builds
  nothing new.
- **Per-machine choices, one tree.** Turn a capability on or off without
  forking the setup — every machine reads the same repository and keeps
  its own flags in one gitignored file.
- **Answers, not archaeology.** `workstation status` and `workstation
  selected` say what this machine carries and what is off;
  `nix store diff-closures` says what a switch changed.

Supported: linux x86_64 and macOS arm64 (WSL counts as linux). The only
prerequisite is nix with flakes; the installer ensures it.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/savioserra/workstation/main/install.sh | sh
```

The guarded form (read what runs first) is the recommended one:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/savioserra/workstation/main/install.sh)"
```

The installer clones to `~/workstation` (`WORKSTATION_CHECKOUT`
overrides; an existing `~/lazyvim` checkout is updated in place) and runs
`workstation init`: a few dialogs prefilled with the detected hostname,
user and home, the fleet choice, and the first switch. Every later update
is the same one-liner or `workstation apply` after a `git pull`.

## The verbs

```sh
workstation apply            # switch this machine to what main builds
workstation rollback         # back to the previous generation
workstation add <path>       # turn a capability on  (workstation remove ...)
workstation selected         # this machine's rows: on, off, baseline
workstation status           # the declared inventory
workstation fleet            # start / join / leave the agent fleet
workstation peers            # pair with agents outside the fleet
workstation help             # the full contract
```

`add`/`remove` take a domain (`editor`, `network`) or a member
(`languages/elixir`, `terminal/nunchux`) and offer the apply. The flags
live in `hosts/local/machine.json` (gitignored) — edit it by hand if you
prefer; an unknown flag is rejected at eval, a typo never silently
no-ops.

Domains: editor, terminal (tmux, nunchux), languages (elixir, go, node,
typescript), fonts, theme, foundation (shell, prompt, the CLI toolset),
secrets, agent, network. Domains default on; `network` and the language
members default off.

## The agent fleet

The machines' assistants call each other over the tailnet. `init` asks
once; `workstation fleet` changes the choice any time:

| Choice | What happens |
| --- | --- |
| Start a new fleet | tailscale on, the tailscale login if needed; this machine serves the fleet |
| Join a fleet | the same, then this machine pairs with every fleet member of your tailscale user |
| Standalone | no tailscale, no fleet |

A join is accepted only when the caller is this node's own tailscale
user; each pair shares one fresh token, stored at both ends. Agents
outside the fleet, and per-peer tuning, go through `workstation peers`.

## Boundaries

- No secret values, provider credentials or vault state in the substrate
  ([docs/secrets.md](docs/secrets.md)).
- Another tailscale install already on the machine stops the apply,
  named — the substrate provisions its own and never removes someone
  else's.
- Ownership and history over time: `home-manager generations`,
  `nix store diff-closures`.

## Documentation

| Reference | Scope |
| --- | --- |
| [docs/index.md](docs/index.md) | Repository navigation |
| [docs/architecture.md](docs/architecture.md) | Declared state and the two clients |
| [docs/capabilities.md](docs/capabilities.md) | Capability boundaries and lifecycle |
| [docs/home-state.md](docs/home-state.md) | Home state law |
| [docs/tools.md](docs/tools.md) | Tool inventory and prerequisites |
| [docs/testing.md](docs/testing.md) | Checks and acceptance |
| [docs/secrets.md](docs/secrets.md) | Authentication boundary |
| [docs/nvim.md](docs/nvim.md), [docs/tmux.md](docs/tmux.md) | Application configuration |
| [AGENTS.md](AGENTS.md) | Contributor rules, checks (`sh .github/scripts/check.sh`), CI |
