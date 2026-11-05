# Workstation capability and lifecycle reference

Declared state is native nix/home-manager: one module per capability domain
under `modules/<domain>/`, module and payload bytes co-located. Reads are
`nix eval` over `workstation.report.<verb>`. Nothing here describes a
surface before its owning commit lands it.

## Dependency direction

```text
flake.nix
  -> nix/lib/machine.nix  (hosts/machine.json: identity + settings)
  -> nix/modules          (workstation-home imports modules/; workstation-system, host)
  -> modules/default.nix  (the domain and member modules, listed)
  -> nix/report.nix       (workstation.report.<verb>: one home eval)
  -> nix/workstation-switch.nix  (the write plane: switch.log receipt)
  -> hosts/{linux,mac}    (the system legs)

bin/workstation (POSIX sh: flake resolution, verb dispatch)
  reads:  nix eval --json <flake>#workstation.report.<verb>
  select: workstation add|remove <path>  (hosts/machine.json settings via jq,
          validated against workstation.report.selectable)
  fleet:  workstation fleet  (the a2a and network flags + the switch;
          the flake's workstation-fleet helper: login, join)
  peers:  workstation peers  (hosts/peers.nix + pairing)
  writes: workstation apply  (execs the staged switch driver)
```

- Reads are pure `nix eval`; mutation is `workstation apply`.
- `bin/workstation` is the sole entry point.
- `modules/**/*.lua` are data payload files, read as bytes, never executed.

## Capability selection

The machine file `hosts/machine.json` carries the identity and
`settings`, a home-manager option tree applied as a module. The committed
copy is the template; the local rewrite stays uncommitted.

```json
{
  "host": "<host>",
  "user": "<user>",
  "home": "<home>",
  "system": "x86_64-linux",
  "settings": {
    "workstation": {
      "network": { "enable": true },
      "languages": { "go": { "enable": true } },
      "terminal": { "nunchux": { "enable": false } }
    },
    "programs": { "hermes": { "a2a": { "enable": true } } }
  }
}
```

| Rule | Mechanism |
| --- | --- |
| Paths | `<domain>` or `<domain>/<member>`: `workstation.<domain>.enable`, `workstation.<domain>.<member>.enable` |
| Validation | the module system: unknown option and wrong type fail the eval |
| Defaults | each enable option's default: domains on, `network` and language members off, `nunchux` on linux only |
| Members | deploy iff `domain.enable && member.enable`; `add <member>` turns a disabled domain on |
| Baseline | `foundation` has no enable option |
| Platform | `terminal/nunchux` asserts linux |
| Reads | `selected` serves `workstation.report.selections`: per path `on`/`off`/`baseline` and the option description |

## Module boundaries

| Module | Contract |
| --- | --- |
| `bin/workstation` | Launcher shim: flake resolution order, verb dispatch, exit codes (dispatch gate: `.github/scripts/shim-dispatch.sh`) |
| `nix/lib/machine.nix` | The machine file: identity, system, settings as home modules |
| `modules/default.nix` | The capability module list |
| `modules/<domain>/<domain>.nix` | The domain's options and declarations, gated on `workstation.<domain>.enable` (members also on their own flag) |
| `nix/report.nix` | The read verbs from one home eval: rows from the option tree, attribution from `definitionsWithLocations` |
| `nix/lib/license.nix` | The secrets domain's unfree acceptance (the 1Password CLI): one predicate, imported by every composition root |
| `modules/agent/agent.nix` | The agent domain's hot-home surfaces: managed skill leaves, the checkout ensure, version-matched skill provisions |
| `modules/<domain>/` payload dirs | Payload assets (`files/`, verify scripts), co-located with the declaring module |
| `modules/theme/tokens.lua` | Canonical theme tokens (data: slot/palette layers, per-appearance palettes) — read as bytes, never executed |

## Declaration contract

- One native nix module per domain, imported by `workstation-home.nix`
  (system-plane toolchains ride `workstation-system.nix` / `home.packages`).
  The module import IS the registration; duplicate options fail the eval.
- Payload bytes live beside the module and are copied into the store at
  eval.
- A capability declares, natively:
  - **file/symlink surfaces** — `home.file` entries with store-path sources
    (intra-home links through `mkOutOfStoreSymlink`);
  - **tools** — packages of the one nixpkgs input; the remaining pins
    declare inline: herdr's `fetchurl`, the
    tmux/nunchux checkouts as hash-pinned `fetchFromGitHub`, the hermes
    checkout as the flake's `hermes-agent` input;
  - **dir claims** — a store tree linked at a home target; overlapping
    targets compose into one derivation;
  - **shell init** — upstream `programs.bash` / `programs.zsh` /
    `programs.starship` / `programs.eza` / `programs.direnv`; ordered
    lines ride `lib.mkOrder` on `initExtra` / `initContent`, env rides
    `home.sessionVariables` (`.profile`, `.zshenv`);
  - **activation scripts** — hot-home and mutation surfaces, sequenced with
    `lib.hm.sequence`;
  - **the switch driver** — the one system-ordered surface: its tail writes
    the receipt; the activation re-points the theme token path.
- No inter-capability ordering graph exists: store closure has no apply
  order. The only ordered surfaces are the ones above.

## Capability graph

Declared data on each module (its domain), consumed by the report:

```text
base       foundation
fonts      fonts
languages  languages/elixir, languages/go, languages/node, languages/typescript (member capabilities)
editor     nvim (+ languages: typescript, elixir declare editor entries)
terminal   terminal/tmux, terminal/nunchux (member capabilities)
theme      theme
agent      agent, herdr
secrets    secrets
```

Domain order is lifecycle order; an unpinned domain name renders appended
and sorted, never hidden.

## Capabilities

### `foundation`
- bash and zsh (`programs.bash`, `programs.zsh`), `~/.local/bin` on
  PATH (`home.sessionPath`), direnv + nix-direnv (the bash hook after the
  prompt init).
- `workstation.foundation.shell.extras` (types.lines, default ""): the
  operator's per-machine rc lines (`settings.workstation.foundation.shell.extras`
  in the machine file), the last lines of `.bashrc` and `.zshrc`.
- Tools, all nixpkgs: fd, ripgrep, lazygit, mise, newt (whiptail, the
  shim's install-time UI).
- The tailscale transport (`workstation.network.tailscale.*`;
  `services.tailscale` on the system legs; on standalone linux the
  `workstation-tailscaled` activation: the substrate's systemd unit, a
  previous apt/dnf/pacman/snap install removed with its sources moved
  aside, `/var/lib/tailscale` kept; off retracts the unit only). The
  machine file's `workstation.network.enable = false` turns the transport off. On darwin
  the system activation removes a previous Tailscale.app (its system
  extension deactivated with the console user's approval), the app's CLI
  shim and the brew formula, moved aside under
  `/var/lib/workstation/tailscale-pre-substrate-<stamp>/`; the substrate
  daemon then logs in as a new node.
- Hosts: all.

### `fonts`
- JetBrainsMono Nerd Font from nixpkgs (`pkgs.nerd-fonts.jetbrains-mono`);
  fontconfig enabled.
- Targets: linux `.local/share/fonts/JetBrainsMonoNerdFont`, darwin
  `Library/Fonts/JetBrainsMonoNerdFont`.
- Verify: the deployed font dir (the container E2E asserts it). Hosts: all.

### `node`
- `pkgs.nodejs_24` on PATH; `.node-version` derived from the runtime
  (one source).
- Verify: `node --version` vs the derived `.node-version` (the container
  E2E asserts both). Hosts: all.

### `agent`
- The hermes runtime pin: the flake's `hermes-agent` input (fetchGit rev,
  surfaced as `outputs.hermesAgentPin` → `programs.hermes.pin`); the
  checkout `~/.hermes/hermes-agent` ensured to the pin by activation —
  clone/fetch only when absent or clean-and-behind, never touching a dirty
  or runtime-advanced tree (the hot-dir law: activation mutates, the file
  plane never tracks).
- The interpreter: `pkgs.python314`, floored at the release the pinned
  rev's `pm/lock.json` carries (the eval dies loud naming both versions on
  a mismatch), claimed at `.local/opt/hermes/python`.
- The launcher: `programs.hermes.package` at `.local/bin/hermes`; resolves
  the interpreter and checkout from `$HOME` at run time, runs the
  interpreter isolated, fails closed with a named message.
- The deployed pin manifest `.local/opt/hermes/pin.json` — the verify
  anchor.
- Skills: `programs.hermes.skills` — one store entry symlink per target
  profile (`default` → `~/.hermes/skills`; named →
  `~/.hermes/profiles/<name>/skills`). The skills parent stays hot
  (`skills_sync` seeds bundled skills; the curator archives there; a
  declared name the pinned tree bundles fails the eval). `secrets` is
  authored at `modules/agent/skills/secrets`; `hsql` is generated from the
  harlequin derivation by `hsql --skill` at build time.
- Gateway extensions: `programs.hermes.extensions` → entry symlinks into
  `~/.hermes/plugins/<name>`.
- The A2A node: `programs.hermes.a2a` (on by default), converged by the
  `converge-hermes-a2a` activation through the hermes CLI:

  | Declared | Lands in `~/.hermes` |
  | --- | --- |
  | `enable`, `port` (9900) | `platforms.a2a.enabled`, `platforms.a2a.extra.port` |
  | `toolsetPlatforms` (`cli`) | the `a2a` toolset per platform |
  | `name` (the identity's host) | `A2A_AGENT_NAME`; with the tailnet bind, `A2A_PUBLIC_URL` `http://<name>:<port>` |
  | `tailnet` | `A2A_HOST` — the node's tailnet IPv4; with no inbound credential, a node-local lock `A2A_BEARER_TOKEN` (generated inside python, held by nobody) widens the bind: the Agent Card is public on the tailnet, calls stay closed until a pairing |
  | `peers` (`hosts/peers.nix`) | one `a2a_agents.<node>` entry each, bearer token `${A2A_PEER_TOKEN_<NODE>}`; `a2a.trusted_peers` (with the fleet roster) |
  | `fleet.enable`, `fleet.port` (9902) | the fleet member service `workstation-fleet serve` (systemd user unit / launchd agent) |
  | the identity's `fleet` | `"standalone"` turns `enable` off; absent or `"member"` keeps it on |

  - Writes run on drift only and verify by re-read; the declaration's keys
    are listed in the state tree's `hermes-a2a.owned` and retracted when
    dropped; operator keys stay untouched.
  - A change restarts a running gateway, unless the apply runs inside it
    (the receipt names `hermes gateway restart`).
  - Tokens: one per node pair, stored by `workstation peers` (pairing) in
    `.env` — `A2A_PEER_TOKEN_<NODE>` out, the `<node>:<token>` row of
    `A2A_PEER_TOKENS` in. The converge reads token names for presence
    only; a pairing leaves `hermes-a2a.restart`, which the next apply
    serves.
- The fleet: members of one tailscale user pair automatically.

  | Endpoint (tailnet IPv4, fleet port) | Answer |
  | --- | --- |
  | `GET /fleet` | `workstation-fleet v1 member=<node>` — the discovery marker |
  | `POST /join` | a fresh pair token, when `tailscale whois` names the caller as this node's tailscale user |

  - A pairing lands at both ends: the token through `workstation-a2a-token`
    (stdin), the runtime entry `a2a_agents.<node>` (the card's skills,
    120s), `a2a.trusted_peers`, the roster `fleet.members` in the state
    tree; the gateway restarts.
  - `workstation fleet` / `workstation init`: Turn on → Start (serve) or
    Join (serve, then pair with every online member of the same tailscale
    user); Not now → standalone. A logged-out node offers `tailscale up`
    first. On the linux home leg, turning on selects the `network` domain.
- `workstation peers`: the hub over the tailnet's A2A agents (the online
  linux/macOS/windows nodes whose Agent Card answers on the A2A port).

  | Action | Effect |
  | --- | --- |
  | add | the agent joins `hosts/peers.nix` with every advertised skill and 120s |
  | pair (tailnet) | a one-shot offer on this node's tailnet IPv4 (A2A port + 1), answered only to the peer's tailnet IPv4, serving the token once; `workstation peers` on the peer finds it and accepts |
  | pair (by hand) | paste the peer's token, or generate one (printed once at exit) — any A2A agent |
  | capabilities, timeout, remove | edit the entry; remove also drops its tokens |

  Token values travel only through the environment into hermes' own `.env`
  writer — never argv, a file or a log.
- Verify: `modules/agent/verify/hermes.sh` — checkout at the deployed pin,
  store-symlink skills, interpreter, launcher `--version` consumer smoke;
  full-stack or exit 1. Hosts: all.
- Runtime-extended state the capability never freezes: the pm-managed
  dependency closure, the tool store (`~/.hermes/tools/…`), the gateway,
  kanban boards, profiles. Updates go through the pin: bump the
  `hermes-agent` rev; the interpreter floor re-derives from the new rev's
  `pm/lock.json`.

### `herdr`
- The one inline `fetchurl` pin (no nixpkgs coverage — upstream ships
  release binaries only), linked from its store derivation at
  `.local/bin/herdr`.
- Verify: fingerprint + link record. Hosts: all.

### `go`
- `pkgs.go`.
- Verify: `go version` (the container E2E asserts it). Hosts: linux/macOS.

### `elixir`
- nixpkgs toolchains via `home.packages` (erlang 28 + elixir 1.18).
- Verify: own Mason expectations and the plugin module through nvim leaf
  helpers. Hosts: all.

### `typescript`
- `pkgs.pnpm`.
- Verify: `pnpm --version` (the container E2E asserts it); own Mason/plugin
  surface. Hosts: all.

### `secrets`
- `pkgs._1password-cli` (unfree — the
  acceptance is `nix/lib/license.nix`, named and scoped); the op env
  (`/etc/pi/op.env`) sourced from the session variables.
- Verify: record + `--version` only, never account or vault state. Hosts:
  all supported.

### `nvim`
- The editor payload (`files/.config/nvim/**`) deployed by the editor
  domain's activation (`deploy-nvim-config`): managed paths overwrite,
  the paths the previous deploy managed that the tree dropped are
  pruned (the state tree's `nvim-managed.list` — a deselected
  language's plugin module leaves with its selection), operator extras
  and the runtime lazy-lock survive. The tree is deliberately not a
  `home.file` surface: the deployed copy is writable, so HM's manifest
  could only refuse a changed managed file, and HM's cleanup only
  deletes its own links. The nixpkgs neovim at
  `.local/bin/nvim` is the domain's `home.file` surface.
- The composed language profile: language capabilities declare profile
  entries as module data (`lazyvim_extras`, `plugin_module`, mason
  packages); one derivation composes them, in declared order, into
  `.config/nvim/lua/languages/profile.lua` (`lib.generators.toLua`; the
  file must `return` the table).
- `EDITOR`/`VISUAL`/`GIT_EDITOR=nvim` as `home.sessionVariables`.
- `.config/nvim/lazy-lock.json`: seeded by the activation merge script
  from the payload baseline, never byte-compared afterwards
  (runtime-extended).
- Verify: startup, locks, mason coverage, base/standard/Go behavior.
  Hosts: all.

### `theme`
- `tokens.lua` is the canonical token payload; nix extracts the slots
  consumers need (fail-closed line parse — a restructure the parser cannot
  read fails the eval). Deploys no home target.
- Verify: token bytes against the tokens module. Hosts: all.

### `terminal`
- `programs.eza` (`ls` = `eza -lh`) and `programs.starship` with
  `.config/starship.toml`.
- Hosts: all.

### `tmux`
- The `terminal/tmux` member capability: plugin checkouts (tpm, tmux2k,
  tmux-yank, tmux-resurrect, vim-tmux-navigator) as hash-pinned
  `fetchFromGitHub`.
- `.tmux.conf`; the `.config/tmux` link; the reply-drain `tmux`
  function in bash and zsh.
- Hosts: linux/macOS.

### `nunchux`
- The `terminal/nunchux` member capability (linux; enabling it on
  darwin fails an assertion): pinned checkout (`.tmux/plugins/nunchux` at
  the v3.1.3 commit, hash-pinned `fetchFromGitHub`, repo-tracked launcher
  binary) + the `.platform` marker composed in; theme-slot launcher
  config rendered natively from `tokens.lua`.
- Hosts: linux (darwin deferred; no release-asset consumer).

## Fresh-host tools

Every tool class ships with the substrate; none stays a documented host
prerequisite. The HOW: the nixpkgs lock carries the versions and
`home.packages` puts the tools on PATH. Inline pins, by exception: herdr
(`fetchurl`), the tmux/nunchux checkouts (`fetchFromGitHub`), the hermes
checkout (the flake input). Every bump moves the owning row and its
consumer together. The hermes manifest (`~/.local/opt/hermes/pin.json`)
keeps its verify lane honest; the plugin checkouts are store paths.

## Grain contract

- Domains and capabilities are rollup rows (capability count, file count,
  last applied generation in the header).
- File rows are the drill-down leaves; never a raw file dump at the top.
- Every file appears exactly once, under its primary capability
  (`hd(attribution)`), remaining contributors as an `also` note; entries
  without attribution land in `unattributed`.

## Validation

Fail-closed at eval:

- the machine file: unknown options and wrong types fail the module
  system (the shim validates paths before writing);
- target collisions across capabilities throw;
- envelope identities in the report are asserted unique;
- the identity gate holds personal identity to `hosts/machine.json`
  (uncommitted).

## Lifecycle

| Phase | Owner | Responsibility |
| --- | --- | --- |
| switch / rollback | `workstation apply` / `workstation rollback` | Build the generation from the flake, activate atomically, write the receipt to `switch.log`; the flake is the resolved checkout's committed `HEAD` (`--flake`, `$WORKSTATION_FLAKE`, the enclosing checkout, `$WORKSTATION_CHECKOUT`) with its working-tree machine files; `WORKSTATION_WORKTREE=1` builds the working tree; an explicit `WORKSTATION_SWITCH_FLAKE` wins; `update` moves `flake.lock` for a commit |
| `plan` / `status` / `capabilities` / `selected` | `nix eval` over `workstation.report` | Answer the declared state; mutate nothing |
| select | `workstation add <path>...` / `workstation remove <path>...` | Validate against `selectable`, set or drop the flag in `hosts/machine.json`, offer the apply (idempotent; the baseline refuses) |
| fleet | `workstation fleet` (and `init`, once) | Choose start / join / standalone; write `programs.hermes.a2a.enable` and `workstation.network.enable`, switch on a change, log in to tailscale, join |
| peers | `workstation peers` | Discover the tailnet's A2A agents, add, pair, tune; write `hosts/peers.nix`, store the pair tokens, offer the apply |
| verify lane | `modules/agent/verify/hermes.sh` | The agent stack's consumer smoke against its recorded pins |

Reads are pure evals. The container E2E (`tests/nix`) asserts the shape
itself: the switch receipt in `switch.log`, and the home carries only
declared targets.

A switch is the one event a generation carries: the receipt line lands in
`switch.log`, and the switch re-points the theme token path
(`~/.local/state/workstation/theme.json`). Consumers read files or watch
the link; nothing polls.

## Payload rule

Host-specific or feature-specific payload stays under the owning
capability as data — no per-capability code hooks, no payload execution:

```text
modules/fonts/files/
modules/languages/node/files/
modules/agent/verify/
```

Anything requiring host execution is a pin derivation, an activation
script, or a verify assertion.

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup (and the composed profile).
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Verify the agent capability's full stack on every host, ending in the
  `hermes --version` consumer smoke — an absent or broken runtime is
  provisioning drift, never a documented state.
- Treat directory existence as supporting evidence, not final proof.
