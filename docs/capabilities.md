# Workstation package and lifecycle reference

## Dependency direction

```text
flake.nix
  -> nix/manifest-lib.nix (the walker: workstation/packages/**/manifest.json
     -> HM/NixOS declarations; fetchurl/download, git-checkout, nvim-profile
     lanes) -> nix/modules (workstation-home, workstation-system)
  -> nix/engine.nix (mixRelease of the umbrella -> the engine release)
  -> nix/workstation-switch.nix (the write plane: switch / rollback / publish)
      -> publish receipt -> the daemon's `system` overlay domain
  -> hosts/<host> (wsl / omarchy / mac; identity only in hosts/<host>/default.nix)

workstation/bin/workstation (POSIX sh: sandbox, checkout anchor, locale guard)
  -> exec the placed elixir release binary
      -> Workstation.CLI.Router (read verbs, TTY contract)
          -> Workstation.Daemon.Read (status.run / plan.run)
      -> Workstation.Pipeline (discover -> resolve -> compose)
          -> Workstation.Core.Catalog.Packages (the tree, discovered)
          -> Workstation.Core.Graph (host selection, requires, topological order)
          -> discovered recipe providers (chezmoi, shared shell,
             nvim-profile) -> deterministic source plan + declared effects

core -X-> catalog/packages/providers/chezmoi/Neovim
```

The engine is Elixir-only: the release binary executes every verb in-process,
there is no Lua execution and no nvim invocation anywhere in the engine path,
and `Workstation.Pipeline` is the one read fold the verbs share. Mutation is
the nix substrate's (`workstation-switch`); `bin/workstation` is the
sole public entry point; nvim is a managed host capability the substrate
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
| `Workstation.Pipeline` | The one read fold: discover -> resolve -> compose; `effects/1` projects the declared mutation program |
| `Workstation.Core.Policy` | Engine-owned legacy tombstones (pure data feeding the plan digest) |
| `Workstation.Core.EngineState` | Fail-closed private state root + canonical JSON |
| `Workstation.Core.Contracts.*` | The declared-program handshake (id/validate_spec/plan_effect; download/git/mise/copy/shell) |
| `Workstation.Backends.Chezmoi` | The recorded-source grammar (validation, `from_recorded`, source names, the declared `:apply` effect) |
| `packages/<name>/` | Package payload assets (`files/`, `dot-*` targets) and data files |
| `packages/theme/tokens.lua` | Canonical theme tokens (DATA: slot/palette layers, per-appearance palettes, consumer choices) — read as bytes, never executed |

## Contribution contract

A package contributes its catalog identity as a **self-contained package
dir** under `workstation/packages/<id>/` — manifest beside payloads (a data
`manifest.json` and/or a manifest module implementing
`Workstation.Core.Catalog.Spec`). There is no
registration list: discovery (`Workstation.Core.Catalog.Discover`) walks
the tree, loads whatever manifest sources it carries, keeps
behaviour-conforming providers
(test-tree sources are excluded deterministically by the beam's recorded
compile path), validates every spec shape, rejects duplicate ids and
orders providers by module name. Adding a package means dropping in a
self-contained dir — zero engine edits.

The spec map declares the package identity, host support, dependencies,
provisioning recipes (`Workstation.Core.Source` constructors) and the
descriptive
`foundation: "foundation/<layer>"` taxonomy entry; payload lives under
`packages/<name>/` and is referenced by relative path. Ordering between
packages comes exclusively from `requires` (necessity + ordering) and the
optional `after` (ordering-only) edges; integer ordering fields
(`order`, `position`, `priority`) are banned on package specs and
rejected at discovery, and graph ties among dependency-equal packages
resolve by id sort. There is no factory, no invocation and no Lua in the
contract: collection is data inspection
(`Catalog.Packages.packages/0`), validation is structural
(`Workstation.Core.Catalog.validations/0` + `Graph`), and the whole path is
deterministic and golden-graded.

Each `contributes` entry is a
`{ provider, spec }` envelope; the `Workstation.Core.Source` constructors
copy options and perform no I/O, target writes or registration. Core
validates only the generic envelope shape; each registered provider
validates its own specs and rejects unknown options. Kinds: `file`,
`directory`, `symlink`, `modify` (one whole inline body or package-relative
asset - structured fragments are the `Workstation.Core.Contracts.Shell` compositor's input
alone and are rejected here) and `remove`. Packages may declare whole-body
`modify` programs for engine-seeded, runtime-extended mutable targets: the
recipe embeds its baseline, the substrate never byte-compares the target, and a
package-owned merge reconciles runtime drift. `lazy-lock.json` under the
nvim package is the reference implementation; see [nvim](nvim.md). Such
recipes inherit the documented whole-body retirement semantics (unsupported
reversal, never auto-removal). Native attributes are `private`,
`executable`, `exact` and `template`; conflicting or unrepresentable
combinations are rejected instead of pretending arbitrary POSIX modes are
encoded. Recipe content is exactly one inline body or a package-relative
asset confined to the owner package (no symlink traversal). The catalog
does not deep-merge records, and package identity is declared only by the
conforming module itself — a package never needs to know that other
packages exist beyond the edges it declares.

Example (the actual theme declaration, abridged):

```elixir
defmodule Workstation.Core.Catalog.Packages.Theme do
  @moduledoc """
  Theme tokens (packages/theme) — a payload-only package.
  """

  @behaviour Workstation.Core.Catalog.Spec

  @impl true
  def spec do
    %{
      id: "theme",
      requires: ["foundation"],
      supported_hosts: %{"darwin" => true, "linux" => true},
      foundation: "foundation/theme",
      contributes: [Workstation.Core.Catalog.Packages.theme_data()]
    }
  end
end
```

`contributes` entries whose payload needs token substitution compose
recipes with the `Workstation.Core.Source` constructors; the theme package
uses `chezmoi_data` — the single source-root `.chezmoidata.toml` token
envelope (the theme canonical tokens are DATA and are read as bytes, never
executed).

## Package graph

`requires` edges carry necessity (the dependency must exist and be enabled
for the host) plus ordering. The optional `after` edge is ordering-only
(systemd `After=` semantics): it sequences the declarer after the target
only when the target is present and enabled on the host — it never pulls a
package in and never fails on absence. Use `after` for pure sequencing
between otherwise-independent packages; use `requires` only when the
dependency is genuinely needed.

```text
foundation
├── fonts
├── node
├── go [Neovim language toolchain]
├── agent [Hermes Agent provisioned full-stack: pinned git checkout, pinned interpreter, engine launcher; managed skills]
├── herdr [pinned terminal-workspace binary; runtime-optional, no server lifecycle]
├── secrets
├── nvim [requires foundation+node+go; owns base/standard/Go profile intents]
├── tmux [linux,darwin]
├── nunchux [requires foundation+theme; linux — pinned checkout (git recipe) + platform marker + theme-slot config]
└── prompt [requires foundation; linux — eza managed `ls` (content-probed linux-only pin: no darwin asset upstream) + starship prompt (both-platform pins): guarded rc fragments + the omarchy-lean starship config]

nvim
├── typescript [requires node+nvim; owns its plugin module, profile intent, the pinned pnpm and verification]
└── elixir [requires nvim; owns its plugin module, profile intent and verification]
```

| Package | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | The CLI tools the editor surface consumes, each a checksum-gated download-contract archive pin at `.local/opt/<tool>` (ripgrep, fd, fzf, lazygit, tree-sitter, rainfrog — per-platform SHA-256 from `versions.json`; the `release` layout for rg/fd/fzf/tree-sitter/rainfrog, `flat` for lazygit's rootless tarball, `zip` for tree-sitter), each probe-gated (`<tool> --version` carries the pinned version) and surfaced on PATH by a `.local/bin/<tool>` link recipe; plus the mise binary pin, the managed mise fragment (it activates the engine's pinned binary by absolute path — the `.local/bin/mise` launcher symlink when it carries its contract link shape, else the sole `.local/opt/mise/<version>/bin/mise` pin, else a silent no-op — and never a bare `mise` from PATH, so a distro mise ranked first can never be paired with the engine's managed data and config), the PATH fragments and the bash-login include fragment (`~/.bash_profile` sources the managed `~/.profile` — bash login shells read `~/.bash_profile` INSTEAD of `~/.profile` when it exists, so a pre-existing hand file can no longer shadow the engine PATH) | — | `download-archive` journal records (probes re-run on claim and on verify) + the link records | All |
| `fonts` | Exact pinned JetBrainsMono Nerd Font tree via the download contract (tar.xz `flat` archive, SHA-256-gated; per-platform `targets`: linux `.local/share/fonts/JetBrainsMonoNerdFont`, darwin `Library/Fonts/JetBrainsMonoNerdFont`); the content probe pins `JetBrainsMonoNerdFont-Regular.ttf` bytes — a data tree with no executable to version; host cache/registration reads the provisioned directory | — | `download-archive` record (the content probe re-runs on claim and on verify) | All |
| `node` | nvm via the download contract (pinned v0.40.4 tarball, exact tree at `.local/opt/nvm`, content probe pins `nvm.sh` bytes) then the pinned Node (tar.xz archive, exact tree at `.local/opt/nvm/versions/node/v<version>`, probe `bin/node --version` = `v{V}`) — declared parent-first so the nested target extracts into the provisioned nvm tree; the rc loader (`.config/shell/nvm.sh`) and `.node-version` recipes unchanged; the rc loader also activates the pinned default — it resolves the recorded nvm `default` alias, falls back to the sole provisioned version when the alias is missing or unresolvable (seeding the alias through nvm itself, once), and exports the same PATH/NVM_BIN/NVM_INC state `nvm use` would set, fork-free, so fresh and reconciled hosts resolve `node` with zero manual steps; an explicit `nvm use` earlier in the shell always wins | — | `download-archive` records (both probes re-run on claim and on verify) + NVM and Node version | All |
| `agent` | Hermes Agent provisioned full-stack: the pinned git recipe (`~/.hermes/hermes-agent` at the `hermes_agent_git_commit` pin), the pinned interpreter (`.local/opt/hermes/python` — a checksum-gated `hermes_python` archive pin, the same python-build-standalone release hermes-agent's own `pm/lock.json` carries at the pinned commit), the engine launcher (`.local/opt/hermes/bin/hermes` payload, resolved at run time) surfaced on PATH as `.local/bin/hermes`, and the managed skills at `~/.hermes/skills/secrets` — served through the copy contract, because the agent home is hot state no backend may track (the retired `lazyvim` skill target carries a recorded-ownership removal tombstone) | — | `packages/agent/verify/hermes.sh` (resources + runtime on every host: checkout HEAD at the pin, managed skill file, pinned interpreter, launcher `--version` consumer smoke; read-only; full-stack or exit 1) | All |
| `go` | Exact pinned toolchain tree via the download contract's archive form (`.local/opt/go` — per-platform SHA-256, member-checked single-root tarball, one root stripped, probe-verified `bin/go version` = `go version go{V}`); go link recipe (`.local/bin/go`) | — | `download-archive` journal record (the probe re-runs on claim and on verify — version drift fails loudly) + the link record | Linux/WSL/macOS |
| `elixir` | `provider: "mise"` tool declarations (erlang 28.5, elixir 1.18.5-otp-27) in `workstation/packages/languages/elixir/manifest.json`; the engine contract (`Workstation.Core.Contracts.Mise`) composes `.config/mise/config.toml` and the managed tool state under the engine state root — no mise payload ships with the package (the mise binary pin and the activation fragment `.config/shell/mise.sh` belong to `foundation`) | — | Own Mason expectations, plugin module and behavior/formatter cases through nvim leaf helpers | All |
| `herdr` | Exact pinned binary via the download contract (`.local/opt/herdr/bin/herdr`, per-platform SHA-256); herdr link recipe | — | Applied-download fingerprint (binary bytes carry the pinned checksum) + the link record; never server/pane/session lifecycle | All |
| `secrets` | Pinned op via the download contract (zip `flat` archive — the `op` + `op.sig` pair — exact tree at `.local/opt/op`, probe `op --version`); op env fragment; op link recipe (`.local/bin/op`) | — | `download-archive` record + the link record; verify only `--version`, never account or vault state | All supported hosts |
| `nvim` | — | Locks and parsers | Startup, locks, mason coverage, base/standard/Go behavior | All |
| `typescript` | The pinned pnpm standalone tree via the download contract (tar.gz `flat` archive — the rootless `pnpm` + `dist/` tree at `.local/opt/pnpm`, probe `pnpm --version` = `{V}`, per-platform SHA-256 from `versions.json`) + the `.local/bin/pnpm` link recipe: the operator's JS package manager is a declared capability, so node-tree reconciliation restores it instead of dropping it as un-owned collateral | — | `download-archive` journal record (the probe re-runs on claim and on verify — version drift fails loudly) + the link record; plus own Mason expectations, plugin module and behavior/formatter cases through nvim leaf helpers | All |
| `theme` | Single source-root `.chezmoidata.toml` token envelope via `provision.chezmoi_data`; deploys no home target | — | Envelope bytes against the tokens module; requires `foundation` | All |
| `tmux` | Plugin checkout; tmux config/theme/link recipes | — | Commits, server, theme | Linux/macOS |
| `nunchux` | Pinned plugin checkout via the git recipe (`.tmux/plugins/nunchux` at the v3.1.3 commit — carries the repo-tracked launcher binary) plus the `.platform` marker (upstream `ensure_binary` never fetches); theme-slot launcher config | — | `packages/nunchux/verify/nunchux.sh` (checkout HEAD + binary content pin + platform marker; read-only, never executes the binary) | Linux (darwin deferred — linux-only package; the darwin release pin stays recorded in `versions.json`) |
| `prompt` | eza + starship via the download contract (eza 0.23.5 — lone-root-file tarball, content probe pins the binary bytes because `eza --version` leads with the tagline; starship 1.27.0 — lone-root-file tarball, exec probe `starship {V}`; both assets mirrored from `versions.json`, exact `.local/opt/<tool>` trees + `.local/bin/<tool>` link recipes); the omarchy-lean starship config at `.config/starship.toml`; marker-guarded rc fragments (`managed-eza` `ls` alias, `managed-starship` per-shell init) into `.bashrc`/`.zshrc` — `command -v` guards keep plain `ls` and no prompt where a tool is absent; `.profile` untouched | — | `packages/prompt/verify/prompt.sh` (pinned bytes + probes + rc wiring; read-only consumer smoke) | Linux (darwin: package off per the 2026-10-20 ruling — eza publishes no darwin_arm64 asset; starship's darwin pin stays recorded in `versions.json` as inventory) |

### Go toolchain acquisition

Decision recorded 2026-10-15 (card t_1d7be74b): the Go toolchain is a
declared ARCHIVE pin, not a host prerequisite. The documented
layout (`.local/opt/go` exact tree + the `.local/bin/go` link) and the
`versions.json` go pins predate the engine's data-manifest cutover but had
no provisioning path — the link dangled on every fresh host. The pin keeps
one pinned-artifact seam (https-only URL, 64-hex
SHA-256 gate, per-platform asset dispatch, exclusive
target ownership) instead of a second lane, and honors the
operating-contract law: a package that names a tool ships the tool.

The archive form is domain-neutral data on the pin: `archive` names the
format, `probe` (argv + first-line output template with `{V}`) is the
honesty gate — the tree must prove it is the pinned tool. Execution is the
walker's: each pin renders as a checksummed `fetchurl` derivation, the
store verifies the bytes, and the generation links the extracted tree at
the target. A pin bump moves the derivation, the generation and the
recorded mirror row together (`go`, `go_<plat>_url`/`_sha256`).

### Fresh-host archive provisioning: foundation tools, fonts, op, nvm/Node

Decision recorded 2026-10-15 (card t_cf14f71b, after the audit t_bf0c0acc
found the docs claiming provisioning no source implemented): every tool
class above is a declared ARCHIVE pin — none stays a documented
host prerequisite, per the operating-contract law. The seam is the same
one contract the go decision grew; the audit's forbidden outcome (docs
claim, source silent) is closed on all four rows. The declared vocabulary,
each shape validated fail-closed and tested:

* formats `tar.xz` and `zip` join `tar.gz` (the store-side extraction has
  no host-tool dependency — a declared format the walker cannot render is
  a loud, named failure, never a silent fallback);
* the declared `layout` names the root discipline — `release` (default:
  exactly one root; a root directory strips one component, a lone root
  file IS the tree — the fzf/tree-sitter shape) and `flat` (rootless
  top-level members — lazygit, the op pair, the font set);
* the probe has a second shape, the content probe
  (`{member, sha256}`), for trees that carry no executable at all —
  nvm's checkout and the font directory prove their identity by pinned
  member bytes instead of faking a version line;
* the destination may dispatch per platform (`targets`, the mirror of
  `assets`) — the font lands in `.local/share/fonts` on linux and
  `Library/Fonts` on darwin; the declared shape travels verbatim, so a
  recorded plan stays machine-independent.

Per-tool seams: ripgrep, fd, fzf, tree-sitter, rainfrog at
`.local/opt/<tool>` + a `.local/bin` link (release layout; lazygit
`flat`); op at `.local/opt/op` + link (zip, `flat`); the JetBrainsMono
Nerd Font exact tree (tar.xz, `flat`, content probe, per-platform
targets; host cache/registration reads the directory); nvm at
`.local/opt/nvm` (release, content probe) with the pinned Node nested at
`.local/opt/nvm/versions/node/v<version>` (release, exec probe),
declared parent-first in the node package's manifest. Every url and
SHA-256 mirrors `versions.json` byte-for-byte — no pin catalog key
changed. The full-home golden envelope carries the provisioned state;
the generation ids move because the pin descriptors are
content-addressed.

## Capability domains

The desired state is presented grouped by **capability domain** — the
`foundation/<name>` lifecycle layers the catalog already declares —
wherever it is listed: the `workstation capabilities` verb (text and
`--json`), and the TUI capabilities browser. One pure view,
`Workstation.CLI.Capabilities.group/1`, folds the existing `status` and
`plan` wires into that envelope, so the CLI listing and the browser cannot
disagree about structure or counts.

Grain contract: domains and packages are rollup rows (package count, file
count, how many files would change, last applied generation in the
header); file rows are the drill-down leaves. Never a raw file dump at the
top level. Every file appears exactly once, under its primary package
(`hd(attribution)`), with remaining contributors shown as an `also` note;
entries without attribution land in an honest `unattributed` bucket.

Domain order is lifecycle order; the mapping today:

| Domain | Packages |
| --- | --- |
| `base` | `foundation` |
| `fonts` | `fonts` |
| `runtime` | `elixir`, `go`, `node`, `typescript` |
| `editor` | `nvim` |
| `terminal` | `nunchux`, `prompt`, `tmux` |
| `theme` | `theme` |
| `agent` | `agent`, `herdr` |
| `secrets` | `secrets` |

A foundation name outside the pinned lifecycle order still renders
(appended, sorted) rather than vanishing — a wrong-grained taxonomy is
surfaced, not hidden.

## Validation

The catalog and graph reject missing or duplicate package identities, invalid
dependency or host-support values, unknown contribution fields, unknown
lifecycle step names and malformed recipe envelopes (`Workstation.Core.Catalog.validations/0`).
Registered providers reject unknown options, unsafe targets
(absolute, traversing, engine-state overlap), conflicting attribute
combinations, unconfined assets and ambiguous modify inputs. The assembler
rejects duplicate exclusive targets, incompatible ancestor types/attributes,
removals overlapping ownership and exact directories encompassing other owners.

The catalog rejects:

- missing or duplicate package identities;
- unknown lifecycle steps or contribution fields;
- invalid dependency or host-support values;
- undeclared foundation layers.

The graph rejects duplicate IDs, unknown dependencies, dependency cycles, and enabled packages that require unsupported packages.

## Lifecycle phases

| Phase | Owner | Responsibility |
| --- | --- | --- |
| switch / rollback | `workstation-switch` (nix) | Build the generation from the flake, activate atomically, publish the receipt to the daemon's `system` domain |
| `plan` | the engine | Validate and preview the attributable desired state (owner, provider, operation, target); mutate nothing |
| `status` / `capabilities` | the engine | Report paths, the resolved graph, the catalog taxonomy and the capability-domain rollups |
| `system applied` | the engine | Read the nix switch receipt (current generation, rollback pointer) |
| verify lane | package `verify/*.sh` | Consumer smokes: deployed versions and observable behavior against the recorded pins |

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
exports `WORKSTATION_ENGINE_REPO` when one exists, so a checkout-launched
release resolves package assets without a preset
environment (the anchor gate is `.github/scripts/shim-anchor.sh`, run by
`check.sh` when a release tarball is built). A bare host matches neither
anchor shape and exports nothing: the release keeps its own fail-closed
detection.

## Neovim package and profile

`packages/editor/nvim` declares the base/standard/Go language intents as
`nvim-profile` recipes; language capabilities such as `typescript`
declare their own intents the same way. The engine composes them
through the discovered `nvim-profile` provider
(`Workstation.Packages.Nvim.Profile`): intents compose in collection order —
the graph's stable walk (dependencies first, ties by id sort; no intent
declares an order number) — the assembled list is validated by the nvim-owned compositor
(`Workstation.Packages.Nvim.Profile`) and ONE attributed chezmoi recipe is
emitted that serializes the deployed
`.config/nvim/lua/languages/profile.lua`. The deployed profile is plain
runtime Lua owned by the editor capability; a tampered deployed copy can
never alter the graph or the desired source because composition is
source-derived. `nvim` requires `foundation`, `node` and `go` explicitly;
`typescript` requires `node` and `nvim`. Dependencies are never inferred
from deployed profile state.

| Consumer | Use |
| --- | --- |
| `packages/editor/nvim/files/.config/nvim/**` | Editor runtime payload (lazy.nvim bootstrap, own behavior verification) |
| `.config/nvim/lua/languages/profile.lua` (deployed) | Generated profile consumed by the editor runtime; serialized by `Workstation.Packages.Nvim.Profile` |

The former package-side compositor and child-verification helpers
(`packages/editor/nvim/{compose,profile,init,leaf,child}.lua`) were engine-side Lua
and died with the engine; the profile contract they enforced now lives in
`Workstation.Packages.Nvim.Profile`.

## Hermes resources

The `agent` capability provisions Hermes Agent **full-stack** (operator
ruling 2026-10-15, "and we still dont have hermes?": the engine owns the
stack — resources-without-runtime is a defect, not a documented manual
step; recorded in AGENTS.md's operating-contract law). The capability owns
four surfaces:

1. **The pinned checkout** — the git recipe (`workstation/versions.json`
   carries `hermes_agent_git_commit` / `hermes_agent_git_url`, upstream
   `NousResearch/hermes-agent`) provisioning `~/.hermes/hermes-agent` at
   the pinned commit.
2. **The pinned interpreter** — a checksum-gated download pin
   (`hermes_python` + per-platform URL/SHA-256 in `workstation/versions.json`)
   installing the python-build-standalone `install_only` archive at
   `.local/opt/hermes/python` (one root stripped, probe
   `bin/python3 --version`). The pin is the SAME release hermes-agent's own
   `pm/lock.json` carries at `hermes_agent_git_commit` — the pinned commit
   is the authority for which interpreter build the runtime expects, and the
   engine mirrors it with the usual URL+SHA-256 discipline.
3. **The engine launcher** — an engine-authored payload at
   `.local/opt/hermes/bin/hermes` (executable), surfaced on PATH as the
   contract-maintained symlink `.local/bin/hermes`. The launcher resolves
   the interpreter and the checkout from `$HOME` at run time (no baked
   paths), runs the interpreter isolated (`-I`, no inherited `PYTHON*`
   config, bytecode kept out of the engine-owned checkout) and fails closed
   with a named message when either pin is missing.
4. **The managed skills** — `~/.hermes/skills/secrets` is served through the
   copy contract (`Workstation.Core.Contracts.Copy`): an idempotent
   byte-compare serve with no derived backend state, because the agent home
   is hot state the agent mutates between applies — any tracked state under
   it would fight those writes and fail every apply on an agent-active host
   (operator ruling 2026-10-15, "stop dir tracking"). The retired `lazyvim`
   skill target carries a recorded-ownership removal tombstone, which
   dir-tracks nothing: removals have no source name and no ancestors.

One verifier, `workstation/packages/agent/verify/hermes.sh`, asserts all of
it on every host and ends in the consumer smoke: `hermes --version` through
the PATH entry must succeed — full-stack or exit 1; a missing or broken
runtime is provisioning drift, never a documented state. Beyond the
consumer gate the runtime stays upstream's: `hermes update`'s pm-managed
dependency closure, tool store (`~/.hermes/tools/...`) and gateway are
runtime-extended state the package never freezes — the engine provisions
the interpreter and the entry point exactly as it provisions mise and nvim,
and upstream's own machinery fills its store from its own locks on demand.
Runtime updates go through the pins: bump `hermes_agent_git_commit`, move
the `hermes_python` pins to the release the new commit's `pm/lock.json`
names, and switch — the new generation provisions the fresh checkout and
interpreter.

Kanban boards and profiles are runtime state the package never owns: the
package ships the pins, the launcher, the skills and the verify only.

## Package payload rule

Host-specific or feature-specific payload logic remains under the owning
package as data or package-owned assets — the engine has no per-package code
hooks and never executes package modules:

```text
packages/fonts/files/
packages/languages/node/files/
packages/agent/verify/
```

Everything the engine must know about a package is declared in its
self-contained manifest beside its payloads
(`workstation/packages/<id>/manifest.json` and/or the manifest module the
loader compiles);
anything requiring host execution is expressed as a declared recipe the
walker renders, a verify assertion the verify lane evaluates, or
package-owned payload the host tool consumes.

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup.
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Verify the agent package's full stack on every host: resources (pinned
  checkout, managed skills) and runtime (pinned interpreter, engine
  launcher) alike, ending in the `hermes --version` consumer smoke — an
  absent or broken runtime is provisioning drift, never a documented state.
- Treat directory existence as supporting evidence, not final proof.
