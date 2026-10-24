# Workstation capability and lifecycle reference

The declared state of the workstation is NATIVE nix/home-manager
declarations: one module per capability domain under `modules/<domain>/`,
the module and the payload bytes it deploys co-located in the domain
directory (renamed directly from `workstation/packages/<domain>/<id>/` by
the absorption chain — see [absorption](absorption.md)). The package-manifest format is retired by
operator ruling 2026-10-21; the walker and the engine's manifest-era
reader plane are gone (the chain's stage 2): the declared state is the
modules' fold, the engine reads the baked report, and the payload bytes
under `workstation/packages/**` stay put until the chain's final card
renames them. Nothing in this reference describes a surface before its
owning commit lands it.

## Dependency direction

```text
flake.nix
  -> modules/* (the native declarations; the capability walk
     nix/lib/capabilities.nix is the registry — the home leg's imports and
     the declared-state report's fold read the same walk)
  -> nix/modules (workstation-home, workstation-system)
  -> nix/engine.nix (mixRelease of the umbrella -> the engine release,
     baking the declared-state report into the release)
  -> nix/workstation-switch.nix (the write plane: switch / rollback / publish)
      -> publish receipt -> the daemon's `system` overlay domain
  -> hosts/<host> (wsl / mac; identity only in hosts/<host>/default.nix)

workstation/bin/workstation (POSIX sh: sandbox, checkout anchor, locale guard)
  -> exec the placed elixir release binary
      -> Workstation.CLI.Router (read verbs, TTY contract)
          -> Workstation.Daemon.Read (status.run / plan.run)
      -> the declared-state report (flake evalReport; the modules' fold,
         nix/report.nix)

core speaks shapes only — the report reader, engine state, the theme platform
```

The engine is Elixir-only: the release binary executes every verb in-process,
there is no Lua execution and no nvim invocation anywhere in the engine path.
Mutation is the nix substrate's (`workstation-switch`); `bin/workstation` is
the sole public entry point; nvim is a managed host capability the substrate
provisions, never an engine dependency.

## Module boundaries

| Module | Contract |
| --- | --- |
| `Workstation.CLI.Router` | Verb parsing, TTY-default contract (`--headless`), exit codes |
| `Workstation.CLI.DaemonClient` | Thin protocol client over the per-user Unix socket (no in-process fallback) |
| `Workstation.CLI.TUI.*` | The one dashboard (engine/capabilities/plan/status boxes, browser, help) |
| `Workstation.CLI.Capabilities` | The capability-domain grouped envelope over the status+plan wires |
| `Workstation.Daemon.Read` | The read engine behind `status.run`/`plan.run` |
| `Workstation.Daemon.*` | The resident daemon: reads, pubsub (`EventBus`), the `system` overlay domain, `Overlay` claim/release |
| `Workstation.Core.Report` | The declared-state report reader: release-baked JSON (or `WORKSTATION_REPORT`), structurally validated, cached per node — the engine's only declared-state source |
| `Workstation.Core.EngineState` | Fail-closed private state root + canonical JSON |
| `modules/<domain>/<domain>.nix` | The domain's native declaration: home.file surfaces, pins, fragments, activation scripts — payload co-located in the domain directory (transitional source: `workstation/packages/<domain>/<id>/`) |
| `nix/lib/pins.nix` | The pin machinery: checksummed `fetchurl`/`fetchGit` derivations, layout/extraction rules, claim composition, build-time probe gates |
| `modules/agent/agent.nix` | The agent domain's hot-home surfaces: managed skill leaves (store-path `home.file`), the checkout ensure and version-matched skill provisions (activation scripts) |
| `workstation/packages/<domain>/<id>/` | Capability payload assets (`files/`, verify scripts) and data files — renames into `modules/<domain>/` with the chain's final card |
| `packages/theme/tokens.lua` | Canonical theme tokens (DATA: slot/palette layers, per-appearance palettes, consumer choices) — read as bytes, never executed |

## The declaration contract

A capability declares once, as a native nix module under
`modules/<domain>/`, imported by `workstation-home.nix`
(the system plane's toolchains ride `workstation-system.nix`/`home.packages`).
There is no registration list: the module import IS the registration, and
nix's module system rejects duplicate options louder than any validator.

The declaration references its payload bytes by relative path under
`workstation/packages/<name>/` — nix copies them into the store at eval
time; payload stays reviewable, syntax-checked, diffable text. The module
owns everything the old envelope kinds expressed, natively:

- **file/symlink surfaces** — `home.file` entries with store-path sources
  (intra-home links through `mkOutOfStoreSymlink`);
- **pins** — `nix/lib/pins.nix` turns a declaration (url + 64-hex sha256 +
  layout + optional probe) into a derivation; the probe (argv + output
  template, or content member+sha for trees without an executable) asserts
  at BUILD time: a wrong pin fails the build, never a host;
- **dir claims** — a pin's tree linked at a home target; overlapping targets
  compose into one derivation (a payload file inside a pinned tree overlays
  into the same store result);
- **shell fragments** — body bytes as payload files; the module declares the
  ordered fragment list (id, target, marker, payload path) and the rc lane
  sources them in declared order;
- **activation scripts** — the hot-home and mutation surfaces (the hermes
  checkout ensure, the nvim lock merge, the retire list), sequenced with
  `lib.hm.sequence`;
- **units** — the daemon user unit and the switch driver, sequenced by
  systemd (`After=`/`WantedBy`).

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
| `foundation` | The base shell environment: the rc lane (fragment bodies as payload files, the declared order — bash-login `.bash_profile` include included), fd/fzf/rg/lazygit/tree-sitter as checksummed pins linked straight from their store trees (`nix/lib/pins.nix`, probes now build gates), eza + starship nixpkgs (the dissolved prompt capability), harlequin + hsql (one upstream distribution via the foundation domain's pin-override overlay; the hsql agent skill provisions at activation, version-matched), and the tailscale transport (`workstation.foundation.tailscale.*`; `services.tailscale` on the system legs) | `packages/prompt/verify/prompt.sh` (the dissolved surface: tools speak, payload deployed, rc wired) | All |
| `fonts` | Exact pinned JetBrainsMono Nerd Font tree (tar.xz `flat`, SHA-256-gated; per-platform targets: linux `.local/share/fonts/JetBrainsMonoNerdFont`, darwin `Library/Fonts/JetBrainsMonoNerdFont`); content probe pins `JetBrainsMonoNerdFont-Regular.ttf` bytes; fontconfig enabled so `fc-cache` sees it | content probe (build gate) | All |
| `node` | nvm (pinned v0.40.4, content probe pins `nvm.sh` bytes) then the pinned Node nested at `.local/opt/nvm/versions/node/v<version>` (probe `bin/node --version`), declared parent-first so the nested tree composes into the nvm tree; the rc loader (`.config/shell/nvm.sh`) and `.node-version` payload unchanged; the loader activates the pinned default fork-free | both probes (build gates) + NVM and Node version | All |
| `agent` | Hermes Agent full-stack: the pinned checkout (`~/.hermes/hermes-agent` at the `hermes_agent_git_commit` pin, ensured by activation — never file-tracked), the pinned interpreter (`.local/opt/hermes/python`, checksum-gated python-build-standalone pin), the engine launcher (`.local/opt/hermes/bin/hermes` payload on PATH as `.local/bin/hermes`), managed skills at `~/.hermes/skills/secrets` (store-path leaves via `modules/agent/agent.nix`); the retired `lazyvim` skill target retires through the declared retire list | `packages/agent/verify/hermes.sh` (checkout at pin, managed skill, interpreter, launcher `--version` consumer smoke; full-stack or exit 1) | All |
| `go` | Exact pinned toolchain tree at `.local/opt/go` (per-platform SHA-256, single-root tarball, probe `bin/go version`) + `.local/bin/go` | probe (build gate) + link record | Linux/WSL/macOS |
| `elixir` | nixpkgs toolchains via `home.packages` (erlang 28 + elixir 1.18; the mise lane retired — toolchains come from nixpkgs) | Own Mason expectations and the plugin module through nvim leaf helpers | All |
| `herdr` | Exact pinned binary linked straight from its store derivation at `.local/bin/herdr` (the `../opt` bin-link shape died with the manifests); never server/pane/session lifecycle | fingerprint + link record | All |
| `secrets` | Pinned op (zip `flat` — the `op` + `op.sig` pair at `.local/opt/op`, probe `op --version`); op env fragment; link record | record + verify `--version` only, never account or vault state | All supported hosts |
| `nvim` | The editor payload (`files/.config/nvim/**`), the nixpkgs neovim on PATH (`.local/bin/nvim`), the composed language profile (see [Neovim](#neovim-package-and-profile)) | Startup, locks, mason coverage, base/standard/Go behavior | All |
| `typescript` | The pinned pnpm standalone tree (tar.gz `flat` — rootless `pnpm` + `dist/`), linked straight from the store derivation at `.local/bin/pnpm`; the operator's JS package manager is a declared capability | probe (build gate) + link record; own Mason/plugin surface | All |
| `theme` | `tokens.lua` — the canonical token payload; nix extracts the slots consumers need (fail-closed line parse in `modules/theme/theme.nix` — a restructure the parser cannot read fails the eval, never renders empty tokens); deploys no home target | token bytes against the tokens module | All |
| `tmux` | Plugin checkouts (tpm, tmux2k, tmux-yank, tmux-resurrect, vim-tmux-navigator — fetchGit-pinned); `.tmux.conf`; the `.config/tmux` link; nixpkgs tmux/btop (the mise lane retired); the stale `tmux2k.conf` theme path retires through the retire list | Commits, server, theme | Linux/macOS |
| `nunchux` | Pinned checkout (`.tmux/plugins/nunchux` at the v3.1.3 commit — repo-tracked launcher binary) + `.platform` marker; theme-slot launcher config rendered natively (slot substitution from `tokens.lua`) | `packages/nunchux/verify/nunchux.sh` (checkout HEAD + binary pin + marker; never executes the binary) | Linux (darwin deferred; the darwin release pin stays recorded in `versions.json`) |
| `prompt` | (dissolved into `foundation` — eza + starship are nixpkgs packages, the starship config and the managed rc fragments ride the foundation module) | `packages/prompt/verify/prompt.sh` (the dissolved surface: tools speak, payload deployed, rc wired) | All |

### Go toolchain acquisition

Decision recorded 2026-10-15 (card t_1d7be74b): the Go toolchain is a
declared ARCHIVE pin, not a host prerequisite. The layout (`.local/opt/go`
exact tree + the `.local/bin/go` link) and the `versions.json` go pins
predate the declaration cutover but had no provisioning path — the link
dangled on every fresh host. The pin keeps one pinned-artifact seam
(https-only URL, 64-hex SHA-256 gate, per-platform dispatch, exclusive
target ownership) and honors the operating-contract law: a capability that
names a tool ships the tool.

The pin's data is domain-neutral: the layout names the root discipline, the
probe is the honesty gate — the tree must prove it is the pinned tool.
Execution is nix's: the declaration renders as a checksummed `fetchurl`
derivation, the store verifies the bytes, and the generation links the
extracted tree at the target. A pin bump moves `versions.json`, the
declaration's consumer row and the generation together.

### Fresh-host pins: foundation tools, fonts, op, nvm/Node

Decision recorded 2026-10-15 (card t_cf14f71b, after the audit t_bf0c0acc
found the docs claiming provisioning no source implemented): every tool
class above is a declared pin — none stays a documented host prerequisite.
The vocabulary, each shape fail-closed:

* formats `tar.xz` and `zip` join `tar.gz` (store-side extraction has no
  host-tool dependency — a declared format the pins library cannot extract
  is a loud, named build failure, never a silent fallback);
* the declared `layout` names the root discipline — `release` (exactly one
  root; a root directory strips one component, a lone root file IS the
  tree) and `flat` (rootless top-level members);
* the probe has a content shape (`{member, sha256}`) for trees that carry
  no executable — nvm's checkout and the font directory prove identity by
  pinned member bytes;
* the destination may dispatch per platform — the font lands in
  `.local/share/fonts` on linux and `Library/Fonts` on darwin.

Per-tool seams: ripgrep, fd, fzf, tree-sitter, rainfrog at
`.local/opt/<tool>` + a `.local/bin` link (release layout; lazygit `flat`);
op at `.local/opt/op` + link (zip, `flat`); the JetBrainsMono Nerd Font
exact tree (tar.xz, `flat`, content probe, per-platform targets); nvm at
`.local/opt/nvm` (release, content probe) with the pinned Node nested
inside it (release, exec probe), declared parent-first. Every url and
SHA-256 mirrors `versions.json` byte-for-byte.

## Capability domains

The declared state is presented grouped by **capability domain** wherever
it is listed: the `workstation capabilities` verb (text and `--json`), and
the TUI capabilities browser. One pure view,
`Workstation.CLI.Capabilities.group/1`, folds the report wires into that
envelope, so the CLI listing and the browser cannot disagree about
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
- pin gates: 64-hex digest shape, platform asset presence, probe output —
  wrong pins fail the derivation build;
- envelope identities in the report are asserted unique (the accounting
  cannot lie);
- the identity gate in `check.sh` holds per-host identity to
  `hosts/<host>/default.nix`.

## Lifecycle phases

| Phase | Owner | Responsibility |
| --- | --- | --- |
| switch / rollback | `workstation-switch` (nix) | Build the generation from the flake, activate atomically, publish the receipt to the daemon's `system` domain |
| `plan` | the engine | Preview the attributable declared state (capability, lane, target) from the report; mutate nothing |
| `status` / `capabilities` | the engine | Report paths, the declared surface, the taxonomy and the capability-domain rollups |
| `system applied` | the engine | Read the nix switch receipt (current generation, rollback pointer) |
| verify lane | `packages/*/verify/*.sh` | Consumer smokes: deployed versions and observable behavior against the recorded pins |

Every engine verb speaks to the workstation DAEMON (`apps/daemon`) —
the resident read server and the only pubsub hub. The CLI and
TUI are thin protocol clients over the per-user Unix socket: reads map to
`status.run`/`plan.run`. The
client's ensure-daemon spawns a daemon detached from the installed release
when the socket is absent or dead (bounded handshake; `workstation daemon
stop` retires it manually); there is no in-process fallback — a missing
daemon is an operator error. On NixOS the daemon runs as the
`workstation-daemon` user unit; the VM boot test (`tests/nix`) pins that
unit and the switch seam.

The daemon publishes generation events: every successful switch ends with
the driver's receipt publish on the `system` overlay domain (the
`system applied` wire op), and subscribed
clients hear the generation change live. The `Overlay` domain claim/release
is unchanged. The historical write plane's op surface —
`bootstrap.run`/`apply.run`/`update.run`/`sync.run`/`verify.run`,
the confirmation-plan flow, the adoption ladder, the stale-pending guard,
the pre-replace daemon drain, the release-refresh handoff and its
rendezvous gate — retired with the engine's write plane (the nix
generation is atomic; rollback replaces every recovery ladder).

The launcher shim (`workstation/bin/workstation`) resolves the checkout repo
anchor — the mix umbrella root — for EVERY verb and
exports `WORKSTATION_ENGINE_REPO` when one exists (the anchor gate is
`.github/scripts/shim-anchor.sh`, run by `check.sh` when a release tarball
is built). A bare host matches neither anchor shape and exports nothing:
the release keeps its own fail-closed detection.

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
transitional; the VM E2E grows an assertion for the deployed profile as the
composition lands natively (it is the absorption chain's named gap).

## Hermes resources

The `agent` capability provisions Hermes Agent **full-stack** (operator
ruling 2026-10-15, "and we still dont have hermes?": the capability owns the
stack — resources-without-runtime is a defect, not a documented manual
step; recorded in AGENTS.md's operating-contract law). Four surfaces:

1. **The pinned checkout** — `versions.json` carries
   `hermes_agent_git_commit` / `hermes_agent_git_url` (upstream
   `NousResearch/hermes-agent`); `~/.hermes/hermes-agent` is ensured to the
   pin by an activation script — clone/fetch only when absent or
   clean-and-behind, never touching a dirty or runtime-advanced tree. The
   hot-dir law: activation mutates, the file plane never tracks.
2. **The pinned interpreter** — a checksum-gated pin (`hermes_python` +
   per-platform URL/SHA-256 in `versions.json`) at
   `.local/opt/hermes/python` (probe `bin/python3 --version`). The pin is
   the SAME release hermes-agent's own `pm/lock.json` carries at the pinned
   commit — the commit is the authority for which interpreter build the
   runtime expects.
3. **The engine launcher** — an engine-authored payload at
   `.local/opt/hermes/bin/hermes` (executable), on PATH as
   `.local/bin/hermes`. The launcher resolves the interpreter and the
   checkout from `$HOME` at run time (no baked paths), runs the interpreter
   isolated (`-I`, no inherited `PYTHON*` config, bytecode kept out of the
   engine-owned checkout) and fails closed with a named message when either
   pin is missing.
4. **The managed skills** — `modules/agent/agent.nix`
   (`workstation.agent.skills`) maps skill names to
   payload dirs and renders each skill leaf as a store-path `home.file`
   (`~/.hermes/skills/secrets` first). The hot-dir law, scoped precisely:
   HM manages declared skill LEAVES — the agent consumes them read-only,
   and an in-place edit is replaced at the next switch (declared truth
   wins) — while the agent's runtime-mutated state (checkout, tools, pm
   store, profiles, boards, memories, sessions) stays untracked forever.
   The retired `lazyvim` skill target retires through the declared retire
   list. The copy contract retires with the format.

One verifier, `packages/agent/verify/hermes.sh`, asserts all of
it on every host and ends in the consumer smoke: `hermes --version` through
the PATH entry must succeed — full-stack or exit 1; a missing or broken
runtime is provisioning drift, never a documented state. Beyond the
consumer gate the runtime stays upstream's: `hermes update`'s pm-managed
dependency closure, tool store (`~/.hermes/tools/...`) and gateway are
runtime-extended state the capability never freezes. Runtime updates go
through the pins: bump `hermes_agent_git_commit`, move the `hermes_python`
pins to the release the new commit's `pm/lock.json` names, and switch.

Kanban boards and profiles are runtime state the capability never owns: it
ships the pins, the launcher, the skills and the verify only.

## Payload rule

Host-specific or feature-specific payload remains under the owning
capability as data — the engine has no per-capability code hooks and never
executes payload modules:

```text
packages/fonts/files/
packages/languages/node/files/
packages/agent/verify/
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
  checkout, managed skills) and runtime (pinned interpreter, engine
  launcher) alike, ending in the `hermes --version` consumer smoke — an
  absent or broken runtime is provisioning drift, never a documented state.
- Treat directory existence as supporting evidence, not final proof.
