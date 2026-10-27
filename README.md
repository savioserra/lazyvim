# workstation

A nixpkgs-native workstation substrate for Linux x86_64 and macOS arm64
(WSL counts as linux). Capability modules — editor, terminal, theme,
languages, foundation, fonts, secrets, agent — are declared once, rendered
by home-manager, and switched by one command. The declared state answers
every question: `nix eval` over `workstation.report.<verb>`. Each switch
writes a receipt to `~/.local/state/workstation/switch.log`.

## Install

```sh
git clone https://github.com/savioserra/lazyvim.git && cd lazyvim
./bin/workstation init   # capture identity + first switch (the shim ships in the clone)
workstation apply    # every later update, rollback, sync
```

`workstation init` runs whiptail dialogs prefilled with the detected
values (hostname, user, home, tailscale fqdn) and writes
`hosts/identity.nix`. Keep that file uncommitted. whiptail ships with the
substrate; on a bare box it falls back to the detected values.

Prerequisite: nix with flakes enabled. The nix daemon is host-owned on
standalone-Home-Manager hosts, platform-managed on NixOS and nix-darwin.

## Hosts

| Host leg | Directory | Plane |
| --- | --- | --- |
| linux (WSL counts as linux) | `hosts/linux` | `homeConfigurations` + `nixosConfigurations` (NixOS-WSL system plane) |
| mac | `hosts/mac` | `darwinConfigurations` (nix-darwin; brew reduced to casks) |

## Reads

```sh
nix eval .#workstation.report.status                # declared inventory (JSON)
nix eval .#workstation.report.plan                  # what the next switch applies
nix eval .#workstation.report.capabilities.editor   # scope with an attrpath

workstation status                 # the same answers through the shim
workstation capabilities editor    # scoped through the shim
workstation help                   # the verb contract
```

The shim reads the generation's flake snapshot
(`~/.local/opt/workstation/flake`) on a switched host, or the enclosing
checkout inside one. Reads mutate nothing. Ownership and history over time:
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
| [docs/endgame.md](docs/endgame.md) | The final shape: structure and invariants |
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

Covers the identity gate, the tree-purity gate, shell checks, the shim
dispatch gate, and the nix eval reads. Never run fixtures against a
switched home. Behavioral acceptance: the container E2E. CI runs the
static battery plus the nix evaluation leg. Release CI validates tagged
source archives and SHA-256 sums.
