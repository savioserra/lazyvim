# Workstation capability and lifecycle reference

Declared state is native nix/home-manager: one module per capability domain
under `modules/<domain>/`, module and payload bytes co-located. Reads are
`nix eval` over `workstation.report.<verb>`. Nothing here describes a
surface before its owning commit lands it.

## Dependency direction

```text
flake.nix
  -> modules/*            (native declarations; the capability walk
                           nix/lib/capabilities.nix is the registry — the
                           home leg and the report fold read the same walk)
  -> nix/modules          (workstation-home, workstation-system, host identity)
  -> nix/report.nix       (the declared-state fold; flake.nix projects
                           workstation.report.{status,plan,capabilities})
  -> nix/workstation-switch.nix  (the write plane behind workstation apply:
                           switch.log receipt in its tail)
  -> hosts/<host>         (linux / mac; identity in hosts/identity.nix)

bin/workstation (POSIX sh: flake resolution, verb dispatch)
  reads:  nix eval --json <flake>#workstation.report.<verb>
  select: workstation add|remove <path>  (hosts/selections.nix, validated
          against workstation.report.selectable; selected renders
          workstation.report.selections)
  writes: `workstation apply` (execs the staged switch driver)
```

- Reads are pure `nix eval`; mutation is `workstation apply`.
- `bin/workstation` is the sole entry point.
- `modules/**/*.lua` are data payload files, read as bytes, never executed.

## Capability selection

Per-machine flags live in `hosts/selections.nix` (the committed copy is
the empty template; the local rewrite stays uncommitted — the
`hosts/identity.nix` lifecycle). The verb grammar is the file grammar:

```nix
{
  enable = [ "languages/typescript" ];   # pinned ON
  disable = [ "terminal/nunchux" ];      # pinned OFF (omitted when empty)
}
```

- Paths mirror the registry: `<domain>` or `<domain>/<member>`
  (`editor`, `languages/typescript`, `terminal/nunchux`), `/`-separated,
  `[A-Za-z0-9_-]` only — validated against `workstation.report.selectable`
  before any write, and re-validated at every eval that reads the file.
- Defaults fill everything unpinned: core domains (editor, terminal,
  theme, fonts, secrets, agent) on; the language MEMBERS off — languages
  are the opt-in granularity; `foundation` is baseline (always on, no
  enable option, refused in both lists).
- A member deploys iff `domain.enable && member.enable`: selecting a
  member implies its domain (the translation in `nix/lib/selections.nix`
  sets both enables), and disabling a domain takes its members with it.
  Pinning a domain off while a member under it is selected is refused at
  read time.
- `workstation.report.selections` resolves every selectable path to
  on/off/baseline/unavailable plus a dependency note (what a remove takes
  with it — `workstation selected` serves it). Availability is probed per
  member (the enable flag forced true vs false over the owning modules, a
  platform truth: the nunchux darwin case renders `unavailable`).
- Every eval of the fold applies the machine's pins, so `plan` and the
  accounting answer for THIS machine's next switch, not the bare
  substrate.

## Module boundaries

| Module | Contract |
| --- | --- |
| `bin/workstation` | Launcher shim: flake resolution order, verb dispatch, exit codes (dispatch gate: `.github/scripts/shim-dispatch.sh`) |
| `flake.nix` `reportVerbs` | The read verbs' projection over the report fold |
| `nix/lib/selections.nix` | The capability selection: pins-file read/validation (grammar, walk membership, baseline, contradictions), the enable-option translation (a member implies its domain), shared by the legs, the e2e personas and the report fold |
| `modules/<domain>/<domain>.nix` | The domain's native declaration: `home.file` surfaces, tools, fragments, activation scripts — each gated on its `workstation.<domain>.enable` (members additionally on their own flag); disabled = definitions skipped, never files missing |
| `nix/report.nix` | The declared-state fold: every capability evaluated once against home-manager, integrity-asserted |
| `nix/lib/capabilities.nix` | The registry walk: discovers `modules/<domain>/` |
| `nix/lib/shell-lane.nix` | The fragment lane's order contract: `order` slots sorted once, read by the rendered rc files and the report's fragmentOrder; a shared or ambiguous slot fails the eval |
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
  - **tools** — nixpkgs packages through `overlays.default` (the
    `nixpkgs-foundation` input), floored in the owning module at its
    declared version (an unapplied overlay or a lagging lock dies loudly at
    the floor); the remaining pins declare inline: herdr's `fetchurl`, the
    tmux/nunchux checkouts as hash-pinned `fetchFromGitHub`, the hermes
    checkout as the flake's `hermes-agent` input;
  - **dir claims** — a store tree linked at a home target; overlapping
    targets compose into one derivation;
  - **shell fragments** — body bytes as payload files; the fragment list
    (id, target, marker, payload, `order` slot) sourced by the rc lane in
    the declared order (`nix/lib/shell-lane.nix` — the slot is PATH
    semantics; the module system's merged list order is reverse module
    order and is never used);
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
- The rc lane: fragment bodies as payload files, declared order slots,
  bash-login `.bash_profile` include.
- Editor env defaults (`EDITOR`/`VISUAL`/`GIT_EDITOR=nvim`) as the
  `managed-editor-env` fragment on every rc target.
- `workstation.foundation.shell.extras` (types.lines, default ""): the
  operator's per-machine rc lines (declared in the identity file as
  `shellExtras`), rendered as the lane's last fragment.
- Tools, all nixpkgs through the foundation overlay, floored:
  fd, fzf, rg, lazygit, tree-sitter; eza + starship; harlequin + hsql
  (the hsql agent skill generated from the harlequin derivation at build
  time); whiptail (the shim's install-time UI).
- The tailscale transport (`workstation.network.tailscale.*`;
  `services.tailscale` on the system legs).
- Verify: `modules/foundation/verify/prompt.sh` — tools speak, payload
  deployed, rc wired, fresh login shell.
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
- `pkgs.go` through the foundation overlay, floored at 1.26.
- Verify: `go version` (the container E2E asserts it). Hosts: linux/macOS.

### `elixir`
- nixpkgs toolchains via `home.packages` (erlang 28 + elixir 1.18).
- Verify: own Mason expectations and the plugin module through nvim leaf
  helpers. Hosts: all.

### `typescript`
- `pkgs.pnpm` through the foundation overlay, floored at major 12.
- Verify: `pnpm --version` (the container E2E asserts it); own Mason/plugin
  surface. Hosts: all.

### `secrets`
- `pkgs._1password-cli` through the foundation overlay (unfree — the
  acceptance is `nix/lib/license.nix`, named and scoped); the op env
  fragment.
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
  deletes its own links. The nixpkgs neovim (floored at 0.12) at
  `.local/bin/nvim` is the domain's `home.file` surface.
- The composed language profile: language capabilities declare profile
  entries as module data (`lazyvim_extras`, `plugin_module`, mason
  packages); one derivation composes them, in declared order, into
  `.config/nvim/lua/languages/profile.lua` (`lib.generators.toLua`; the
  file must `return` the table).
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

### `tmux`
- The `terminal/tmux` member capability: plugin checkouts (tpm, tmux2k,
  tmux-yank, tmux-resurrect, vim-tmux-navigator) as hash-pinned
  `fetchFromGitHub`.
- `.tmux.conf`; the `.config/tmux` link; the deployed pin manifest
  `.tmux/plugins.pins.json` rendered from `workstation.terminal.pins`
  (each terminal member contributes its rows); the stale `tmux2k.conf`
  theme path retires through the retire list.
- Verify: commits, server, theme. Hosts: linux/macOS.

### `nunchux`
- The `terminal/nunchux` member capability (linux-only — the platform
  gate lives inside the file plane; the report marks the path
  `unavailable` on darwin): pinned checkout (`.tmux/plugins/nunchux` at
  the v3.1.3 commit, hash-pinned `fetchFromGitHub`, repo-tracked launcher
  binary) + the `.platform` marker composed in; theme-slot launcher
  config rendered natively from `tokens.lua`; the manifest row rides
  `workstation.terminal.pins`.
- Verify: `modules/terminal/nunchux/verify/nunchux.sh` (checkout HEAD +
  binary pin + marker; never executes the binary). Hosts: linux (darwin
  deferred; no release-asset consumer).

## Fresh-host tools

Every tool class ships with the substrate; none stays a documented host
prerequisite. The HOW: the flake's `overlays.default` carries the
version-currency set, the owning modules assert the floors, and
`home.packages` puts the tools on PATH. Inline pins, by exception: herdr
(`fetchurl`), the tmux/nunchux checkouts (`fetchFromGitHub`), the hermes
checkout (the flake input). Every bump moves the owning row and its
consumer together. The floors and the deployed manifests
(`~/.tmux/plugins.pins.json`, `~/.local/opt/hermes/pin.json`) keep the
verify lanes honest.

## Grain contract

- Domains and capabilities are rollup rows (capability count, file count,
  last applied generation in the header).
- File rows are the drill-down leaves; never a raw file dump at the top.
- Every file appears exactly once, under its primary capability
  (`hd(attribution)`), remaining contributors as an `also` note; entries
  without attribution land in `unattributed`.

## Validation

Fail-closed at eval:

- the fold's integrity assertions — a misclassified module file throws,
  never silently shrinks the report; declared fragments/retire lists agree
  between the fold and the composed surface;
- the selections file: malformed paths, unknown paths, baseline pins, and
  domain-disabled-under-a-selected-member contradictions all throw at
  every eval that reads it (the shim validates before writing; the
  library validates before every read)
- target collisions across capabilities throw;
- the fragment order contract: no slot without a fragment id, no id with
  two slots, no slot shared by two ids;
- version floors: a tool below its floor throws, naming the overlay and
  the lock;
- envelope identities in the report are asserted unique;
- the identity gate holds personal identity to `hosts/identity.nix`
  (uncommitted).

## Lifecycle

| Phase | Owner | Responsibility |
| --- | --- | --- |
| switch / rollback | `workstation apply` / `workstation rollback` | Build the generation from the flake, activate atomically, write the receipt to `switch.log` |
| `plan` / `status` / `capabilities` / `selected` | `nix eval` over `workstation.report` | Answer the declared state; mutate nothing |
| select | `workstation add <path>...` / `workstation remove <path>...` | Validate against the walk-derived `selectable`, edit `hosts/selections.nix` canonically, offer the apply (idempotent; the baseline refuses) |
| verify lane | `modules/*/verify/*.sh` | Consumer smokes against the recorded pins |

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
