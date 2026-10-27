# Workstation capability and lifecycle reference

The declared state of the workstation is NATIVE nix/home-manager
declarations: one module per capability domain under `modules/<domain>/`,
the module and the payload bytes it deploys co-located in the domain
directory (the format's retirement is recorded in
[absorption](absorption.md)). The package-manifest format is retired by
operator ruling 2026-10-21; the walker and the engine's manifest-era
reader plane are gone, and the engine itself retired with them: the
declared state is the modules' fold, and reads are `nix eval` over
`workstation.report.<verb>`. Nothing in this
reference describes a surface before its
owning commit lands it.

## Dependency direction

```text
flake.nix
  -> modules/* (the native declarations; the capability walk
     nix/lib/capabilities.nix is the registry — the home leg's imports and
     the declared-state report's fold read the same walk)
  -> nix/modules (workstation-home, workstation-system, host identity)
  -> nix/report.nix (the declared-state fold; flake.nix projects it as
     workstation.report.{status,plan,capabilities})
  -> nix/workstation-switch.nix (the write plane: switch / rollback, the
     switch.log receipt in its tail)
  -> hosts/<host> (wsl / mac; identity only in hosts/<host>/default.nix)

bin/workstation (POSIX sh: flake resolution, verb dispatch)
  -> reads:  nix eval --json <flake>#workstation.report.<verb>
  -> writes: exec the staged workstation-switch driver
```

There is no engine: no resident process, no wire protocol, no TUI, no
Elixir plane. Mutation is the nix substrate's (`workstation-switch`);
`bin/workstation` is the sole public entry point; nvim is a managed host
capability the substrate provisions. `modules/**/*.lua` are data payload
files read as bytes, never executed.

## Module boundaries

| Module | Contract |
| --- | --- |
| `bin/workstation` | The launcher shim: flake resolution order, verb dispatch, exit codes (the dispatch gate: `.github/scripts/shim-dispatch.sh`) |
| `flake.nix` `reportVerbs` | The read verbs' projection over the report fold — the operator-facing read contract |
| `modules/<domain>/<domain>.nix` | The domain's native declaration: home.file surfaces, pins, fragments, activation scripts — payload co-located in the domain directory |
| `nix/report.nix` | The declared-state fold: every capability evaluated once against home-manager, integrity-asserted (targets compose, nothing escapes classification, no identity leaks) |
| `nix/lib/capabilities.nix` | The registry walk: discovers `modules/<domain>/` — the one discovery the home leg and the fold share |
| `nix/lib/shell-lane.nix` | The fragment lane's order contract: the fragments' `order` slots sorted once, read by both the rendered rc files and the report's fragmentOrder; a shared or ambiguous slot fails the eval |
| `nix/lib/license.nix` | The secrets domain's license acceptance (the 1Password CLI rides nixpkgs unfree): one predicate, imported by every composition root |
| `modules/agent/agent.nix` | The agent domain's hot-home surfaces: managed skill leaves (store-path `home.file`), the checkout ensure and version-matched skill provisions (activation scripts) |
| `modules/<domain>/` payload dirs | Capability payload assets (`files/`, verify scripts) and data files, co-located with the declaring module |
| `modules/theme/tokens.lua` | Canonical theme tokens (DATA: slot/palette layers, per-appearance palettes, consumer choices) — read as bytes, never executed |

## The declaration contract

A capability declares once, as a native nix module under
`modules/<domain>/`, imported by `workstation-home.nix`
(the system plane's toolchains ride `workstation-system.nix`/`home.packages`).
There is no registration list: the module import IS the registration, and
nix's module system rejects duplicate options louder than any validator.

The declaration references its payload bytes by relative path beside it
(under `modules/<domain>/`) — nix copies them into the store at eval
time; payload stays reviewable, syntax-checked, diffable text. The module
owns everything the old envelope kinds expressed, natively:

- **file/symlink surfaces** — `home.file` entries with store-path sources
  (intra-home links through `mkOutOfStoreSymlink`);
- **tools** — nixpkgs packages through the flake's pin-override overlay
  (`overlays.default`, the `nixpkgs-foundation` input), each floored in
  its owning module at the retired download pin's version (the harlequin
  precedent — an unapplied overlay or a lagging lock dies loudly at the
  floor, never a quiet downgrade). The remaining pins declare inline in
  their owning modules: herdr's `fetchurl`, the tmux/nunchux checkouts as
  hash-pinned `fetchFromGitHub`, the hermes checkout as the flake's
  `hermes-agent` input;
- **dir claims** — a store tree linked at a home target; overlapping
  targets compose into one derivation (a payload file inside a claimed
  tree overlays into the same store result — the terminal module's
  `.platform` marker is the one consumer of that HOW since the pins
  library retired);
- **shell fragments** — body bytes as payload files; the module declares
  the fragment list (id, target, marker, payload, ORDER slot) and the rc
  lane sources them in the declared order (nix/lib/shell-lane.nix sorts
  by the slot — PATH semantics, never the module system's merged list
  order, which is REVERSE module order; the eval fails on a shared or
  ambiguous slot);
- **activation scripts** — the hot-home and mutation surfaces (the hermes
  checkout ensure, the nvim lock merge, the retire list), sequenced with
  `lib.hm.sequence`;
- **the switch driver** — the one system-ordered surface: a switch is the
  event; its tail writes the receipt and the activation re-points the
  theme token path.

Ordering between capabilities does not exist as a graph: store closure has
no apply order. The only ordered surfaces are the ones above (fragment list,
activation sequence, unit dependencies).

## Capability graph

The taxonomy is declared data on each module (its domain), consumed by the
report and rendered grouped wherever the declared state is listed:

```text
base       foundation
fonts      fonts
runtime    elixir, go, node, typescript
editor     nvim (+ languages: typescript, elixir declare editor entries)
terminal   nunchux, prompt, tmux
theme      theme
agent      agent, herdr
secrets    secrets
```

| Capability | Provides | Verify | Host support |
| --- | --- | --- | --- |
| `foundation` | The base shell environment: the rc lane (fragment bodies as payload files, the declared order slots — bash-login `.bash_profile` include included), fd/fzf/rg/lazygit/tree-sitter as nixpkgs packages through the foundation domain's pin-override overlay, floored at the retired download pins' versions (`modules/foundation/foundation.nix`), eza + starship nixpkgs (the dissolved prompt capability), harlequin + hsql (one upstream distribution via the same overlay; the hsql agent skill is generated from the harlequin derivation at build time and serves as a declared entry symlink), and the tailscale transport (`workstation.foundation.tailscale.*`; `services.tailscale` on the system legs) | `modules/foundation/verify/prompt.sh` (the dissolved surface: tools speak, payload deployed, rc wired) | All |
| `fonts` | The JetBrainsMono Nerd Font from nixpkgs (`pkgs.nerd-fonts.jetbrains-mono` through the foundation domain's overlay — the retired tar.xz content probe died with the pins machinery); the package's font directory deploys at the per-platform targets (linux `.local/share/fonts/JetBrainsMonoNerdFont`, darwin `Library/Fonts/JetBrainsMonoNerdFont`); fontconfig enabled so `fc-cache` sees it | the deployed font dir (the VM E2E asserts it) | All |
| `node` | The nixpkgs runtime (`pkgs.nodejs_24` on PATH — operator ruling 2026-10-27 retired nvm with the pins machinery: nix owns the runtime, the default-alias bug class died structurally); `.node-version` is DERIVED from the runtime (one source); `.local/opt/nvm` and `.config/shell/nvm.sh` retire through the declared tombstones | the runtime's `node --version` vs the derived `.node-version` (the VM E2E asserts both) | All |
| `agent` | Hermes Agent full-stack, declarative under `programs.hermes` (`modules/agent/agent.nix`): the runtime pin rides the flake's `hermes-agent` input (fetchGit rev, surfaced as `outputs.hermesAgentPin` -> `programs.hermes.pin`); the pinned checkout (`~/.hermes/hermes-agent`) is ensured to the pin by activation — never file-tracked; the interpreter is `pkgs.python314` (the foundation input; floored at the release the pinned rev's `pm/lock.json` carries — the eval dies loud on a mismatch) claimed at `.local/opt/hermes/python`; the engine launcher (`programs.hermes.package`, on PATH as `.local/bin/hermes`); the deployed pin manifest (`.local/opt/hermes/pin.json`) is the verify anchor; declared skills serve as ONE store entry symlink per target profile (`programs.hermes.skills` — `secrets` authored at `modules/agent/skills/secrets`, `hsql` generated from the harlequin derivation); gateway extensions link as entry symlinks into `~/.hermes/plugins`; herdr keeps the ONE inline download pin (no nixpkgs coverage — documented in the owning module); the retired `lazyvim` skill target retires through the declared retire list | `modules/agent/verify/hermes.sh` (checkout at the deployed pin, store-symlink skills, interpreter, launcher `--version` consumer smoke; full-stack or exit 1) | All |
| `go` | The nixpkgs toolchain (`pkgs.go` through the foundation domain's overlay, floored at 1.26 — the retired 1.27.1 pin's line rises with the next lock) on PATH | the toolchain's `go version` (the VM E2E asserts it) | Linux/WSL/macOS |
| `elixir` | nixpkgs toolchains via `home.packages` (erlang 28 + elixir 1.18; the mise lane retired — toolchains come from nixpkgs) | Own Mason expectations and the plugin module through nvim leaf helpers | All |
| `herdr` | The ONE inline download pin (no nixpkgs coverage — upstream ships release binaries only; documented in `modules/agent/agent.nix`), linked straight from its store derivation at `.local/bin/herdr`; never server/pane/session lifecycle | fingerprint + link record | All |
| `secrets` | The nixpkgs 1Password CLI (`pkgs._1password-cli` through the foundation domain's overlay; unfree — the acceptance is `nix/lib/license.nix`, named and scoped); op env fragment | record + verify `--version` only, never account or vault state | All supported hosts |
| `nvim` | The editor payload (`files/.config/nvim/**`), the nixpkgs neovim on PATH (`.local/bin/nvim`), the composed language profile (see [Neovim](#neovim-package-and-profile)) | Startup, locks, mason coverage, base/standard/Go behavior | All |
| `typescript` | The nixpkgs pnpm (`pkgs.pnpm` through the foundation domain's overlay, floored at the retired pin's major 12); the operator's JS package manager is a declared capability | the toolchain's `pnpm --version` (the VM E2E asserts it); own Mason/plugin surface | All |
| `theme` | `tokens.lua` — the canonical token payload; nix extracts the slots consumers need (fail-closed line parse in `modules/theme/theme.nix` — a restructure the parser cannot read fails the eval, never renders empty tokens); deploys no home target | token bytes against the tokens module | All |
| `tmux` | Plugin checkouts (tpm, tmux2k, tmux-yank, tmux-resurrect, vim-tmux-navigator — hash-pinned `fetchFromGitHub`, hermetic and in-store; the un-locked `fetchGit` calls retired); `.tmux.conf`; the `.config/tmux` link; nixpkgs tmux/btop (the mise lane retired); the stale `tmux2k.conf` theme path retires through the retire list | Commits, server, theme | Linux/macOS |
| `nunchux` | Pinned checkout (`.tmux/plugins/nunchux` at the v3.1.3 commit — hash-pinned `fetchFromGitHub`, repo-tracked launcher binary) + `.platform` marker composed in (the claim composition's one consumer, inline in the terminal module); theme-slot launcher config rendered natively (slot substitution from `tokens.lua`) | `modules/terminal/nunchux/verify/nunchux.sh` (checkout HEAD + binary pin + marker; never executes the binary) | Linux (darwin deferred; the release-asset rows retired with the inventory — no consumer) |
| `prompt` | (dissolved into `foundation` — eza + starship are nixpkgs packages, the starship config and the managed rc fragments ride the foundation module) | `modules/foundation/verify/prompt.sh` (the dissolved surface: tools speak, payload deployed, rc wired) | All |

### Go toolchain acquisition

Decision recorded 2026-10-15 (card t_1d7be74b): the Go toolchain is a
declared capability, never a host prerequisite. The archive-pin era (the
`.local/opt/go` exact tree + the `.local/bin/go` link) closed with the
pins machinery (operator ruling 2026-10-27): the toolchain is
`pkgs.go` through the foundation domain's pin-override overlay, floored
in `modules/languages/go/go.nix` at the retired pin's minor (1.26) — an
unapplied overlay or a lagging lock dies loudly at the floor, and the
version line rises with the next `nix flake update` instead of a SHA
being kept alive by hand.

### Fresh-host tools: the overlay + the remaining pins

Decision recorded 2026-10-15 (card t_cf14f71b, after the audit t_bf0c0acc
found the docs claiming provisioning no source implemented): every tool
class above ships with the substrate — none stays a documented host
prerequisite. Since operator ruling 2026-10-27 the HOW is nixpkgs:
the flake's `overlays.default` (the `nixpkgs-foundation` input) carries
the version-currency set, the owning modules assert the floors, and
`home.packages` puts the tools on PATH. What remains a literal pin
declares inline in its owning module: herdr (the inline `fetchurl`), the
tmux/nunchux checkouts (hash-pinned `fetchFromGitHub` — owner/repo/rev/
hash, hermetic and in-store), and the hermes checkout (the flake input).
Every bump moves the owning row and its consumer together; the floors
and the deployed manifests (`~/.tmux/plugins.pins.json`,
`~/.local/opt/hermes/pin.json`) keep the verify lanes honest.

## Capability domains

The declared state is presented grouped by **capability domain** wherever
it is listed: `nix eval .#workstation.report.capabilities` (scope with an
attrpath — `.#workstation.report.capabilities.editor`) and the shim's
`workstation capabilities` wrapper answer from the same fold, so the raw
eval and the wrapper cannot disagree about
structure or counts.

Grain contract: domains and capabilities are rollup rows (capability count,
file count, last applied generation in the header); file rows are the
drill-down leaves. Never a raw file dump at the top level. Every file
appears exactly once, under its primary capability (`hd(attribution)`),
with remaining contributors shown as an `also` note; entries without
attribution land in an honest `unattributed` bucket.

Domain order is lifecycle order:

| Domain | Capabilities |
| --- | --- |
| `base` | `foundation` |
| `fonts` | `fonts` |
| `runtime` | `elixir`, `go`, `node`, `typescript` |
| `editor` | `nvim` |
| `terminal` | `nunchux`, `prompt`, `tmux` |
| `theme` | `theme` |
| `agent` | `agent`, `herdr` |
| `secrets` | `secrets` |

A domain name outside the pinned lifecycle order still renders (appended,
sorted) rather than vanishing — a wrong-grained taxonomy is surfaced, not
hidden.

## Validation

Validation is nix eval, fail-closed at eval time:

- the report fold's integrity assertions: the per-capability surfaces must
  compose to the full evaluation (a misclassified module file throws, never
  silently shrinks the report), and the declared fragments/retire lists
  must agree between the fold and the composed surface;
- target collisions across capabilities throw at eval (two lanes claiming
  one home target never silently compose);
- the fragment lane's order contract: a fragment without a slot, one id
  with two slots, or two ids sharing a slot fails the eval
  (nix/lib/shell-lane.nix — the lane's order is PATH semantics);
- the version floors: a tool below its owning module's floor throws
  naming the overlay and the lock (a quiet downgrade never passes);
- envelope identities in the report are asserted unique (the accounting
  cannot lie);
- the identity gate in `check.sh` holds per-host identity to
  `hosts/<host>/default.nix`.

## Lifecycle phases

| Phase | Owner | Responsibility |
| --- | --- | --- |
| switch / rollback | `workstation-switch` (nix) | Build the generation from the flake, activate atomically, write the receipt to the state tree's `switch.log` |
| `plan` / `status` / `capabilities` | `nix eval` over `workstation.report` (the shim wraps it) | Answer the declared state; mutate nothing |
| verify lane | `modules/*/verify/*.sh` | Consumer smokes: deployed versions and observable behavior against the recorded pins |

Reads are pure evals — there is no resident process and no socket. The
daemon (the resident read server, the pubsub hub, the `system`/`theme`
overlay domains and the per-user Unix socket) retired with the engine:
the VM boot test (`tests/nix`) pins the retirement itself — no daemon
unit, no socket — plus the switch receipt in `switch.log`.

A switch is the one event a generation carries: the driver's tail appends
the receipt line to `switch.log`, and the switch re-points the theme token
path (`~/.local/state/workstation/theme.json`) — consumers read files or
watch the link, nothing polls. The historical write plane's op surface —
`bootstrap.run`/`apply.run`/`update.run`/`sync.run`/`verify.run`,
the confirmation-plan flow, the adoption ladder, the stale-pending guard,
the pre-replace daemon drain, the release-refresh handoff and its
rendezvous gate — retired with the engine's write plane (the nix
generation is atomic; rollback replaces every recovery ladder).

## Neovim package and profile

The editor capability declares its payload (`files/.config/nvim/**`) as
`home.file` surfaces and the nixpkgs neovim as `.local/bin/nvim` — the
bootstrap pin is replaced loudly at eval (the payload must still declare
the link; the drift guard fires on both sides). Language capabilities
(`typescript`, `elixir`) declare their profile entries as module data:
`lazyvim_extras`, `plugin_module` and mason packages. A nix derivation
composes them, in declared order, into ONE deployed
`.config/nvim/lua/languages/profile.lua` (`lib.generators.toLua`
serialization, the byte shape pinned by a derivation-output golden). A
tampered deployed copy can never alter the declared source because
composition is derivation-derived.

| Consumer | Use |
| --- | --- |
| `packages/editor/nvim/files/.config/nvim/**` | Editor runtime payload (lazy.nvim bootstrap, own behavior verification) |
| `.config/nvim/lua/languages/profile.lua` (deployed) | Composed profile consumed by the editor runtime; built by the nvim capability's derivation |
| `.config/nvim/lazy-lock.json` | The pinned plugin lock: seeded by the activation merge script from the payload baseline, never byte-compared afterwards (runtime-extended) |

The manifest-era compositor (`Workstation.Packages.Nvim.Profile`) is
retired: the composition is native (the editor capability's derivation —
the absorption chain's named gap, closed), and the VM E2E asserts the
deployed profile.

## Hermes resources

The `agent` capability provisions Hermes Agent **full-stack** (operator
ruling 2026-10-15, "and we still dont have hermes?": the capability owns the
stack — resources-without-runtime is a defect, not a documented manual
step; recorded in AGENTS.md's operating-contract law). Four surfaces:

1. **The runtime pin** — the flake's `hermes-agent` input, pinned by
   fetchGit rev (`flake.nix`, the agent domain's pin surface) and surfaced
   as `outputs.hermesAgentPin` -> `programs.hermes.pin`; the activation
   ensure moves `~/.hermes/hermes-agent` to the pin — clone/fetch only
   when absent or clean-and-behind, never touching a dirty or
   runtime-advanced tree. The hot-dir law: activation mutates, the file
   plane never tracks. The checkout stays hot because the runtime writes
   into it (update machinery, the pm store, recovery closures); a full
   derivation is the named alternative, deferred until hermeticity
   demands it. The deployed pin manifest (`.local/opt/hermes/pin.json`)
   carries the pin for the verify lane — the deployed pin, never a repo
   file.
2. **The interpreter** — `pkgs.python314` (nixpkgs-owned via the
   foundation domain's pin-override overlay), claimed at
   `.local/opt/hermes/python` (probe `bin/python3 --version`). Its
   version floor is DERIVED at eval from the SAME release hermes-agent's
   `pm/lock.json` carries at the pinned rev — the rev is the authority
   for which interpreter build the runtime expects, and the eval dies
   loud naming both versions on a mismatch.
3. **The engine launcher** — `programs.hermes.package`, deployed at
   `.local/opt/hermes/bin/hermes` and on PATH as `.local/bin/hermes`. The
   launcher resolves the interpreter and the checkout from `$HOME` at run
   time (no baked paths), runs the interpreter isolated (`-I`, no
   inherited `PYTHON*` config, bytecode kept out of the engine-owned
   checkout) and fails closed with a named message when either pin is
   missing.
4. **The declared skills** — `programs.hermes.skills`
   (`modules/agent/agent.nix` renders, owning capabilities set): each
   enabled skill serves as ONE store entry symlink per target profile
   (`profiles` — "default" is `~/.hermes/skills`, a named profile is
   `~/.hermes/profiles/<name>/skills`). The entry is atomic: a switch
   replaces the whole skill; an in-place edit fails on the read-only
   store — declared truth wins, loudly. The skills PARENT stays hot (the
   hot-dir law): `skills_sync` seeds hermes' bundled skills there and the
   curator archives there; a build-time assertion refuses a declared name
   the pinned tree bundles (skills_sync owns that name and would fight
   the link). `secrets` is authored at `modules/agent/skills/secrets`;
   `hsql` is generated from the harlequin derivation by `hsql --skill` at
   build time (the hsql precedent: version-matched, offline). Gateway
   extensions (`programs.hermes.extensions`) link the same way into
   `~/.hermes/plugins/<name>`, where user discovery outranks bundled;
   per-plugin enablement stays live state.

One verifier, `modules/agent/verify/hermes.sh`, asserts all of
it on every host and ends in the consumer smoke: `hermes --version` through
the PATH entry must succeed — full-stack or exit 1; a missing or broken
runtime is provisioning drift, never a documented state. Beyond the
consumer gate the runtime stays upstream's: `hermes update`'s pm-managed
dependency closure, tool store (`~/.hermes/tools/...`) and gateway are
runtime-extended state the capability never freezes. Runtime updates go
through the pin: bump the `hermes-agent` input's rev (`nix flake lock`
follows), and the interpreter's floor re-derives from the new rev's
`pm/lock.json` at eval — if the nixpkgs set lags the locked release, the
eval dies loud naming both versions and the fix is a lock update.

Kanban boards and profiles are runtime state the capability never owns: it
ships the pin, the launcher, the skills and the verify only.

## Payload rule

Host-specific or feature-specific payload remains under the owning
capability as data — the substrate has no per-capability code hooks and never
executes payload modules:

```text
modules/fonts/files/
modules/languages/node/files/
modules/agent/verify/
```

Everything the substrate must know about a capability is declared in its
native module; payload bytes are referenced by relative path and copied
into the store at eval. Anything requiring host execution is a pin
derivation, an activation script, or a verify assertion the verify lane
evaluates. The payload home co-locates into `modules/<domain>/` when the
absorption chain's final card lands.

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup (and the composed profile).
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Verify the agent capability's full stack on every host: resources (pinned
  checkout, managed skills) and runtime (interpreter, engine
  launcher) alike, ending in the `hermes --version` consumer smoke — an
  absent or broken runtime is provisioning drift, never a documented state.
- Treat directory existence as supporting evidence, not final proof.
