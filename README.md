# LazyVim workstation

Nix-substrate workstation for pinned Neovim, tmux configuration and Pi
resources on Linux x86_64 (including WSL-as-Linux) and macOS arm64.
Nix owns the lifecycle — pins, the file plane, activation and rollback —
and every question about the declared state is answered by `nix eval` over
`workstation.report.<verb>`. There is no engine: no resident process, no
socket, no release to build. A switch's receipt lands in the state tree's
`switch.log`.

## Prerequisites

- Nix with flakes enabled (the one hard prerequisite — the daemon is
  host-owned on standalone-Home-Manager legs, platform-managed on
  NixOS/nix-darwin ones).
- `workstation init` captures the machine's identity once, at install
  time, into `hosts/identity.nix` (whiptail dialogs prefilled with the
  detected values; keep the file uncommitted). whiptail ships with the
  substrate (`pkgs.newt`); a bare box before its first switch falls back
  to the detected values verbatim. The flake renders every pinned tool
  into the store.
- The legs: `hosts/linux` (the linux leg; NixOS-WSL system plane, `homeConfigurations` +
  `nixosConfigurations`), `hosts/mac` (nix-darwin, `darwinConfigurations`;
  brew reduced to casks). WSL counts as the linux leg (operator ruling
  2026-10-22: the flake targets exactly mac and linux). A NixOS VM boot
  test (`tests/nix`) proves the daemonless shape end to end: no unit, no
  socket, the apply-driven switch, the receipt, the consumer smokes.

## Hosts

Switch a host through the substrate — the leg-native rebuild, or the
`workstation-switch` driver (staged into each generation; it wraps the
leg-native switch and writes the receipt):

```sh
sudo nixos-rebuild switch --flake .#wsl      # linux leg (NixOS-WSL)
darwin-rebuild switch --flake .#mac          # macOS leg (nix-darwin)

workstation-switch apply            # leg-native switch + the switch.log receipt
workstation-switch rollback         # atomic rollback to the prior generation
```

Every switch ends with a receipt line in the state tree's `switch.log`
(`~/.local/state/workstation/switch.log`):

```sh
tail -n 5 ~/.local/state/workstation/switch.log   # generation N applied (rollback available at M)
```

## Reads: nix eval, nothing else

The declared state is the capability modules under `modules/` — module and
payload bytes co-located in one directory; the fold (`nix/report.nix`)
reports the composed surface, and the flake projects it as the read verbs.
`workstation status|plan|capabilities` (the launcher shim, `bin/workstation`)
are thin wrappers over exactly these evals; on a nix-managed home they read
the generation's own flake snapshot (`~/.local/opt/workstation/flake`), and
inside a checkout they read the checkout.

```sh
nix eval .#workstation.report.status          # the declared inventory (JSON)
nix eval .#workstation.report.plan            # the surface the next switch applies (+ digest)
nix eval .#workstation.report.capabilities.editor   # scope with an attrpath

workstation status         # the same answers through the shim (thin wrapper)
workstation capabilities editor
workstation help           # the verb contract; the bare verb prints usage
```

The read verbs never mutate a home; mutation is `workstation-switch`'s
alone. Ownership and baseline over time are the nix generation's story
(`home-manager generations`, `nix store diff-closures`).

The theme's live surface is a store token path
(`~/.local/state/workstation/theme.json`) the switch re-points every
generation; consumers read it or watch the link — nothing polls.

`~/.hermes` stays hot home: home-manager never manages it. The pinned
hermes checkout carries its runtime writes (update machinery, the pm
store, recovery closures); managed skill leaves are read-only store
symlinks the declarative agent module owns.

## Secrets and ownership

No login profiles, secret values, provider credentials, 1Password account
sessions, or vault state belong to the substrate. The source-managed ntfy
notifier and pinned Pi packages retain their own discovery/reload
contracts; see the references below.

## Documentation and validation

| Reference | Scope |
| --- | --- |
| [`docs/endgame.md`](docs/endgame.md) | The final shape: structure, invariants, retirement ledger |
| [`docs/index.md`](docs/index.md) | Repository navigation |
| [`docs/testing.md`](docs/testing.md) | Fast checks, the docker-nix acceptance, the VM E2E |
| [`docs/capabilities.md`](docs/capabilities.md) | Capability boundaries and lifecycle |
| [`docs/home-state.md`](docs/home-state.md) | Home state law (native declarations) and the cutover history |
| [`docs/tools.md`](docs/tools.md) | Managed inventory and prerequisites |
| [`docs/secrets.md`](docs/secrets.md) | User-owned authentication and explicit secrets skill |
| [`docs/nvim.md`](docs/nvim.md), [`docs/tmux.md`](docs/tmux.md) | Application configuration |
| `AGENTS.md` | Contributor rules |

Run `sh .github/scripts/check.sh` for the static battery (identity gate,
engine-free gate, shell checks, the shim dispatch gate, the nix eval reads
where nix exists); never run fixtures directly against a switched home.
Real nix builds and VM boots require explicit authorization; follow
[testing](docs/testing.md), not a live-home experiment. CI runs the static
battery plus a nix evaluation leg (closure builds stay the local docker
acceptance's job). Release CI validates before producing tagged source
archives and SHA-256 sums.
