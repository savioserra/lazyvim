# workstation

A nixpkgs-native workstation substrate for Linux x86_64 and macOS arm64
(WSL counts as linux). Capability modules — editor, terminal, theme,
languages, foundation, fonts, secrets, agent — are declared once, rendered
by home-manager, and switched by one command. The declared state answers
every question: `nix eval` over `workstation.report.<verb>`. Each switch
writes a receipt to `~/.local/state/workstation/switch.log`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh | sh
```

The guarded form (read what runs first) is the recommended one:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh)"
```

`install.sh` ensures nix (the one prerequisite), clones the repo to
`~/lazyvim` (`WORKSTATION_CHECKOUT` overrides), and runs `workstation
init` — the machine capture, the fleet choice and the first switch.
Every later update is `workstation apply`.

`workstation init` runs whiptail dialogs prefilled with the detected
values (hostname, user, home) and writes `hosts/local/machine.json`
(gitignored, seeded from `hosts/template/`). whiptail ships with the
substrate; on a bare box it falls back to the detected values.

Prerequisite: nix with flakes enabled. The nix daemon is host-owned on
standalone-Home-Manager hosts, platform-managed on NixOS and nix-darwin.

## Hosts

| Host leg | Directory | Plane |
| --- | --- | --- |
| linux (WSL counts as linux) | `hosts/linux` | `homeConfigurations` + `nixosConfigurations` (NixOS-WSL system plane) |
| mac | `hosts/mac` | `darwinConfigurations` (nix-darwin; brew reduced to casks) |

## Selecting capabilities

A machine's capability flags live in `hosts/local/machine.json` under `settings`:

```sh
workstation add languages/typescript terminal/nunchux   # enable
workstation remove terminal/nunchux                      # disable
workstation selected                                     # this machine's rows
```

Paths are `<domain>` or `<domain>/<member>`, the option paths
`workstation.<domain>.enable` and `workstation.<domain>.<member>.enable`
(`workstation selected` lists them all). Defaults: domains on, `network`
and the language members off, `foundation` baseline. `add` and `remove`
set the flag and offer `apply now?`; the file can also be edited by hand —
the module system rejects an unknown flag.

## Agent fleet (A2A)

The machines' agents call each other over tailscale. `workstation init`
asks once; `workstation fleet` changes the choice any time:

| Choice | What happens |
| --- | --- |
| Start a new fleet | tailscale on (the substrate's daemon; another tailscale install stops the apply, named), the tailscale login if needed; this machine serves the fleet |
| Join a fleet | the same, then this machine pairs with every fleet member of your tailscale user |
| Standalone | no tailscale, no agent fleet (`fleet = "standalone"` in the identity) |

| Fleet member | Detail |
| --- | --- |
| service | `workstation-fleet serve` (systemd user unit / launchd agent) on the tailnet IPv4, port 9902 |
| trust | a join is accepted when `tailscale whois` names the caller as this node's tailscale user |
| pairing | one fresh token per pair, stored at both ends in `~/.hermes/.env`; the peer entry and the trust land in the hermes config, the gateway restarts |

Agents outside the fleet, and per-peer tuning, go through the peers hub:

```sh
workstation peers    # the hub: discover, add, pair, tune, save
workstation apply    # serve the change
```

| Step | What happens |
| --- | --- |
| discover | the tailnet's online nodes whose Agent Card answers on :9900 |
| pair | Pair on one machine, `workstation peers` on the other: one shared token, exchanged over the tailnet, stored in `~/.hermes/.env` |
| peers | `hosts/local/peers.nix` (gitignored) |

## Reads

```sh
nix eval .#workstation.report.status                # declared inventory (JSON)
nix eval .#workstation.report.plan                  # what the next switch applies
nix eval .#workstation.report.capabilities.editor   # scope with an attrpath

workstation status                 # the same answers through the shim
workstation capabilities editor    # scoped through the shim
workstation selected               # this machine's selection rows
workstation help                   # the verb contract
```

The shim reads the enclosing checkout, or the checkout `init` recorded
when run elsewhere. Reads and switches build the checkout's committed
`HEAD` with the working tree's `hosts/` machine files (the `machine-files`
input), so uncommitted work stays out of the generation and a commit that
touches nothing deployed leaves the generation unchanged;
`WORKSTATION_WORKTREE=1` builds the working tree. The switch receipt in
`switch.log` names the commit. Reads mutate nothing. Ownership and history over time:
`home-manager generations`, `nix store diff-closures`.

The switch re-points the theme token path
(`~/.local/state/workstation/theme.json`) every generation. Consumers read
the file or watch the link.

`~/.hermes` stays hot home: home-manager never manages it. The pinned
hermes checkout carries the runtime writes; managed skill leaves are
read-only store symlinks.

## Secrets

No login profiles, secret values, provider credentials, 1Password account
sessions, or vault state belong to the substrate. See
[docs/secrets.md](docs/secrets.md).

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
| [AGENTS.md](AGENTS.md) | Contributor rules |

## Checks

```sh
sh .github/scripts/check.sh
```

Covers the identity gate, the history-prose gate, shell checks, the shim
dispatch gate, and the nix eval reads. Never run fixtures against a
switched home. Behavioral acceptance: the container E2E. CI runs the
static battery plus the nix evaluation leg. Release CI validates tagged
source archives and SHA-256 sums.
