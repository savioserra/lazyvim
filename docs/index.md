# Repository reference

## Path map

| Path | Role |
| --- | --- |
| `README.md` | Host switching, the read verbs |
| `AGENTS.md` | Repository-wide implementation rules |
| `flake.nix`, `nix/` | The substrate: the capability walk, the declared-state report fold and its read verbs, the switch driver, the home/system/host modules |
| `bin/workstation` | The launcher shim (POSIX sh): flake resolution + verb dispatch; reads are nix evals, writes delegate to the staged `workstation-switch` |
| `hosts/` | `linux` (the linux leg; NixOS-WSL system plane), `mac` (nix-darwin); identity is the tracked template `hosts/identity.nix`, rewritten per machine by `workstation init` (kept uncommitted) |
| `.github/workflows/ci.yml` | The static battery + the nix evaluation leg |
| `.github/workflows/release.yml` | Tagged source archives |
| `modules/` | Capability domains, one directory each — module + payload bytes co-located (adding a capability is adding one directory) — each domain owns its tools (nixpkgs via the overlay + floors) and its remaining pins |

## Documentation map

| Document | Scope |
| --- | --- |
| [`capabilities.md`](capabilities.md) | Dependency direction, declaration contract, lifecycle phases |
| [`home-state.md`](home-state.md) | Home state law: native declarations, hot-home scope, legacy cutover |
| [`tools.md`](tools.md) | Managed tool inventory and platform coverage |
| [`testing.md`](testing.md) | Offline checks, the docker-nix acceptance and the container E2E |
| [`architecture.md`](architecture.md) | Declared state + two clients, the read verbs, the write plane |
| [`secrets.md`](secrets.md) | 1Password boundary, vault scope, Pi skill policy |
| [`nvim.md`](nvim.md) | Editor entry points, profile, plugins, locks |
| [`tmux.md`](tmux.md) | Settings, plugin pins, theme |
| [`theme.md`](theme.md) | Shared color tokens, slot/palette layers, derived pi themes |
| [`herdr.md`](herdr.md) | Pinned Herdr binary and official Pi hook, ownership and compatibility gates |

## Substrate law (binding)

The substrate is nixpkgs-native: declared state + two clients.
There are **no deprecated or backward-compatibility surfaces**: one current
shape per verb, per option, per pin — hard-cut. Retired paths are dropped
in the lane that touches them — delete, don't deprecate. The filesystem is
the capability registry; reads are `nix eval` over `workstation.report`;
verification is behavioral (docs/architecture.md is the anchor). Lua appears
only as live payload data (deployed editor config, theme tokens read as
bytes), never executed.
