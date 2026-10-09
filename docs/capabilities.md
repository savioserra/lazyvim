# Workstation package and lifecycle reference

## Dependency direction

```text
workstation/bin/workstation (POSIX sh: sandbox + runtime/release acquisition)
  -> exec elixir release binary
      -> Workstation.CLI.Router (verbs, TTY contract)
          -> Workstation.CLI.Core (read side) / Workstation.CLI.Engine (lifecycle)
      -> Workstation.Core.Plan (shared composition)
          -> Workstation.Core.Catalog.Packages (native catalog data modules)
          -> Workstation.Core.Graph (host selection, requires, topological order)
          -> Workstation.Core.Source.* (provider registry: chezmoi, chezmoi_data,
             shell, nvim-profile) -> deterministic source plan
      -> Workstation.Core.ApplyEngine (under Core.ApplyLock) / Update.* steps
          -> Workstation.Core.Provisioner (chezmoi backend, exact generation)
          -> Workstation.Core.Journal + EngineState (generations, lock, journal)

core -X-> catalog/packages/providers/chezmoi/Neovim
```

The engine is Elixir-only: the release binary executes every verb in-process,
there is no Lua execution and no nvim invocation anywhere in the engine path,
and `Workstation.Core.Plan.composed_plan/2` is the single plan composition the
daemon applier and the one-shot CLI driver share. `bin/workstation` is the
sole public entry point; nvim is a managed host capability installed at
bootstrap, never an engine dependency.

## Module boundaries

| Module | Contract |
| --- | --- |
| `Workstation.CLI.Router` | Verb parsing, TTY-default contract (`--headless`), exit codes |
| `Workstation.CLI.Core` | Read-side evaluation (`status`, `plan`, `diff`, `json`) with state-root bracketing |
| `Workstation.CLI.Engine` | One-shot lifecycle driver (`bootstrap`, `apply`, `update`, `sync`, `verify`, `pull`) under the apply lock |
| `Workstation.CLI.TUI.*` | Interactive apply/update screens (optimus CLI + term_ui) |
| `Workstation.Core.Plan` | The shared collect -> graph -> plan -> baseline composition |
| `Workstation.Core.Catalog.Packages` | Native catalog: one pure-data contribution module per package, DISCOVERED at runtime (no registration list) |
| `Workstation.Core.Catalog.Spec` | The package-spec provider behaviour + spec shape validation (including the banned integer-ordering fields) |
| `Workstation.Core.Catalog.Discover` | Runtime provider discovery (`:code.all_available/0` + behaviour conformance, test-tree exclusion, duplicate-id rejection) |
| `Workstation.Core.Graph` | Host selection, `requires` (necessity + ordering) and `after` (ordering-only) edges, topological ordering with id-sort ties |
| `Workstation.Core.Source.*` | Recipe providers (`Source.Chezmoi`, `Source.ChezmoiData`, `Source.Shell`, `Source.NvimProfile`) |
| `Workstation.Core.ApplyEngine` | Preconditions, publish, backend apply, journal record, post-apply verify |
| `Workstation.Core.Provisioner` | Chezmoi backend with an exact generation |
| `Workstation.Core.Policy` | Engine-owned legacy tombstones |
| `Workstation.Core.{Journal,EngineState,ApplyLock}` | Immutable generations, fail-closed private state tree, exclusive apply lock |
| `packages/<name>/` | Package payload assets (`files/`, `dot-*` targets) and data files |
| `packages/theme/tokens.lua` | Canonical theme tokens (DATA: slot/palette layers, per-appearance palettes, consumer choices) — read as bytes, never executed |

## Contribution contract

A package contributes its catalog identity through a **pure-data Elixir
module** under `elixir/apps/core/lib/workstation/core/catalog/packages/`
(one module per package) that declares `@behaviour
Workstation.Core.Catalog.Spec` and implements `spec/0`. There is no
registration list: discovery (`Workstation.Core.Catalog.Discover`) scans
the loaded code namespace for `Workstation.Core.Catalog.Packages.*`
providers via `:code.all_available/0`, keeps behaviour-conforming modules
(test-tree sources are excluded deterministically by the beam's recorded
compile path), validates every spec shape, rejects duplicate ids and
orders providers by module name. Adding a package means dropping in a
conforming module — zero engine edits.

The spec map declares the package identity, host support, dependencies,
provisioning recipes (`Workstation.Core.Source` constructors), lifecycle
steps (`Workstation.Core.Update` step atoms) and the descriptive
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
asset - structured fragments are the `Source.Shell` compositor's input
alone and are rejected here) and `remove`. Packages may declare whole-body
`modify` programs for engine-seeded, runtime-extended mutable targets: the
recipe embeds its baseline, apply never byte-compares the target, and a
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
│   └── agent [pi coding agent + internal pi-packages.json pinned catalog; delegates installs to the pi CLI]
│   ├── pi-skills [requires agent]
│   └── pi-ntfy-notifier [source-managed]
├── go [Neovim language toolchain]
├── herdr [pinned terminal-workspace binary; runtime-optional, no server lifecycle]
├── secrets
├── nvim [requires foundation+node+go; owns base/standard/Go profile intents]
└── tmux [linux,darwin]

nvim
└── typescript [requires node+nvim; owns its plugin module, profile intent and verification]

herdr
└── herdr-pi [requires agent+herdr; owns only the official Pi hook bytes]
```

| Package | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | CLI archive members | — | CLI versions | All |
| `fonts` | Font archives, then host registration/cache | — | Host visibility | All |
| `node` | nvm and Node archives, then default/environment | — | NVM and Node version | All |
| `agent` | Exact global pi npm package; internal pi packages from `pi-packages.json`, installed via the pinned pi CLI; subagent skill policy; pi-subagents role definitions with per-project memory frontmatter; acp.json delegate-off | — | npm/CLI version, per-package lock integrity, pinned settings entries, role definition files with memory frontmatter, extension discovery tools | All |
| `pi-skills` | — | — | Managed skill files and Pi discovery | All |
| `pi-ntfy-notifier` | Source-managed extension | — | Manifest version, extension files, node test suite | All |
| `go` | Exact toolchain archive; go link recipe | — | Go version | Linux/WSL/macOS |
| `herdr` | Exact pinned binary; herdr link recipe | — | Static binary version only; never server/pane/session lifecycle | All |
| `herdr-pi` | — (official hook deploys as a file recipe) | — | Exact hook bytes, integration revision marker, isolated Pi loader discovery | All |
| `secrets` | Pinned op archive member; op env fragment | — | Managed 1Password CLI version; never account or vault state | All supported hosts |
| `nvim` | — | Locks and parsers | Startup, locks, mason coverage, base/standard/Go behavior | All |
| `typescript` | — | — | Own Mason expectations, plugin module and behavior/formatter cases through nvim leaf helpers | All |
| `theme` | Single source-root `.chezmoidata.toml` token envelope via `provision.chezmoi_data`; deploys no home target | — | Envelope bytes against the tokens module; requires `foundation` | All |
| `tmux` | Plugin checkout; tmux config/theme/link recipes | — | Commits, server, theme | Linux/macOS |

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
| `runtime` | `node`, `go` |
| `editor` | `nvim`, `nvim-typescript`, `helix` |
| `terminal` | `tmux`, `herdr`, `herdr-pi` |
| `theme` | `theme` |
| `agent` | `agent`, `pi-skills`, `pi-ntfy-notifier` |
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

| Phase | Input state | Responsibility |
| --- | --- | --- |
| `bootstrap` | Whole source checkout, shell prerequisites | Install verified pinned runtime/backend, then the engine provisions and verifies the conflict-safe public launcher symlink |
| `plan` | Source declarations and journal | Validate and preview attributable change sets, generated-source patches, target preconditions and unsupported reversals; mutate nothing |
| `diff` | Same desired-state generation as apply | Ensure backend, preview file changes only; no retirement/setup/sync/verify |
| `apply` | Validated plan | Retire owned real-account legacy service (never scratch), publish the immutable generation, apply through the backend, refresh Node pin/PATH, setup |
| `setup` | Applied target home | Provision package archives and configure host state |
| `sync` | Configured applications | Restore mutable application state |
| `verify` | Complete target home | Assert versions and observable behavior |
| `update` | Git clone | Checked pull --ff-only, release refresh, bootstrap, apply, sync, verify; stop at first failure |

Every lifecycle verb is served by the workstation DAEMON (`apps/daemon`) —
the only mutation engine and the only source of live state. The CLI and
TUI are thin protocol clients over the per-user Unix socket: reads map to
`status.run`/`plan.run`/`diff.run`, lifecycle verbs to
`bootstrap.run`/`apply.run`/`update.run`/`sync.run`/`verify.run`, and
`update` carries the whole chain in ONE op (a `steps` sub-chain). The
client's ensure-daemon spawns a daemon detached from the installed release
when the socket is absent or dead (bounded handshake; `workstation daemon
stop` retires it manually); there is no in-process fallback — a missing
daemon is an operator error, because the apply lock must have exactly one
owner. Long ops stream structured events (`run.started`/`step.started`/
`step.done`/`run.log`/`run.finished`, stamped with an `op_ref`) that both
the headless lines and the TUI rows render; `op.abort` cancels the running
op at its NEXT STEP BOUNDARY (never mid-step — a boundary is the only
honest cancellation point for a lock-holding chain) and reports `aborted`;
detaching (`q`) lets the daemon finish without a viewer. Recorded TUI
deferrals: the abort key forwards `op.abort` with the stream's `op_ref`,
which the screens learn from the `run.started` frame — an abort pressed
before that first frame is a recorded no-op (the key is inert, the run
continues) — and the TUI renders run/step boundaries only, so
`apply.run`'s entry-level progress and `run.log` tails stay deferred
until core applier hooks exist (core/ is frozen by contract). The daemon also
serves the read-only `update.check` — `git ls-remote origin` vs local HEAD
on the install repo the update verb pulls, 5 s bound, 10-minute TTL cache —
answering `up_to_date`, `behind{local,remote,remote_ref}` or
`unknown{reason}`; `status` merges it as an additive optional `update`
object (absent when unknown), and the TUI shows the passive accent
indicator `↑ update available (abc1234 → def5678) — [u] update` only when
behind, with `[u]` launching the standard update flow. See the engine
architecture in [docs/elixir.md](elixir.md).

Bootstrap's engine step owns the `~/.local/bin/workstation` launcher symlink:
identical canonical target, conflicting user files refused, no completion
after a backend failure. Update refreshes the installed release from the
freshly pulled checkout before the lifecycle steps so pin and engine changes
take effect: when the engine checkout carries a buildable `elixir/` umbrella
(the anchor resolution matches the launcher shim's), the platform is
supported and the `mise` toolchain is present, the bootstrap step runs the
same `bootstrap/install-runtime.sh` acquisition a fresh machine takes. The
installer stamps every activated release with the source HEAD it built
(`.built-from` beside the release); a stamp equal to the current checkout
HEAD makes the refresh a no-op, so the update handoff terminates, and a
failed build aborts the chain instead of continuing under stale code. A bare
host (no checkout) keeps the runtime-only bootstrap contract — the update
chain refreshes nothing engine-side there, and the designed engine-upgrade
path is re-running the acquisition from a checkout (`workstation bootstrap`).

Because a refresh changes the release ON DISK while the running process
keeps its OLD loaded code, the chain hands off — ENTIRELY daemon-side
since the client/daemon refactor: the daemon's chained `update.run`
captures the WRITER's identity as of before the installer re-stamps the
release (`.built-from` stamp; an in-place refresh reuses the same release
root, so identity can never be the path), writes the handoff note under
the destination state root (writer stamp + the REMAINING steps), answers
the op with the `handoff` outcome, and stops itself. The CLIENT observes
the disconnect, re-spawns the daemon from the REFRESHED release
(ensure-daemon, bounded handshake), and re-sends the remaining sub-chain —
the fresh daemon consumes the note, resumes the remaining steps under the
same lock, clears the note after the resumed chain exits 0, and the
operator sees one banner, one chain, one exit code. Identity is compared,
never assumed: the refreshed code consuming a note of its OWN stamp is the
resume target; an AGED stamp (the note predates the operator's newer
checkout) means the note is stale — it is consumed with no resume (the
designed engine-upgrade path is re-running `workstation bootstrap`, which
also self-heals a stranded note), so the chain never resurrects steps an
operator already superseded. The note names identity only; the client's
re-spawn derives its daemon binary from the release ROOT
(`<root>/bin/workstation`, guarded to be an existing executable), never
from the identity token — spawning the stamp as a path is the 2026-10-05
P0. A handoff decision after the final step is a no-op (never an empty
resume), and a failing resumed chain is echoed once, never retried. The
TUI does not survive a rebuild: interactive operators re-run
`workstation update`, which the refresh stamp makes a fast no-op rebuild
path. See [installation and daily use](../README.md).

The launcher shim (`workstation/bin/workstation`) resolves the checkout repo
anchor — the directory holding the `elixir/` umbrella — for EVERY verb and
exports `WORKSTATION_ENGINE_REPO` when one exists, so a checkout-launched
release resolves package assets and update steps without a preset
environment (the anchor gate is `.github/scripts/shim-anchor.sh`, run by
`check.sh` when a release tarball is built). A bare host matches neither
anchor shape and exports nothing: the release keeps its own fail-closed
detection.

## Neovim package and profile

`packages/editor/nvim` declares the base/standard/Go language intents as
`nvim-profile` recipes; language capabilities such as `typescript`
declare their own intents the same way. The engine composes them
(`Workstation.Core.Source.NvimProfile.compose/1`): intents are ordered by an
explicit `order` key (Go, TypeScript, standard) with graph collection order as
the tie-breaker, the assembled list is validated (mirroring the deployed
`packages/editor/nvim/profile.lua` contract) and ONE attributed chezmoi recipe is
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
| `.config/nvim/lua/languages/profile.lua` (deployed) | Generated profile consumed by the editor runtime; serialized by `Workstation.Core.Source.NvimProfile.compose/1` |

The former package-side compositor and child-verification helpers
(`packages/editor/nvim/{compose,profile,init,leaf,child}.lua`) were engine-side Lua
and died with the engine; the profile contract they enforced now lives in
`Workstation.Core.Source.NvimProfile`.

## Pi resources

The `agent` capability owns the pi coding agent and every internal pi package.
The coding agent is pinned in the canonical `workstation/versions.json`; internal
packages (pi-subagents, pi-web-access, billion-context-pi, pi-simplify, openwiki)
are pinned with exact versions and registry integrity in the package-local
`workstation/packages/agent/pi-packages.json` catalog. All install work is
delegated to the pinned pi CLI (`pi install npm:<name>@<version>`); the engine
asserts the catalog, then verifies installed versions, settings entries and
package-lock integrity. Host-side `pi update` drift is converged back to the
catalog by the next apply, never followed.

The agent capability also owns the subagent skill policy (worker/delegate get the
managed lazyvim skill) and `~/.pi/acp.json` with `delegate: false`, keeping
pi-subagents as the only delegation surface while billion-context-pi compression
tools stay enabled. It also ships the engine-owned pi-subagents role definitions
(`~/.pi/agent/agents/{worker,reviewer}.md`, sourced from
`workstation/packages/agent/files/.pi/agent/agents/`). These shadow the bundled
builtins and carry `memory: {scope: project, path: fleet}` frontmatter — per-agent
memory is intrinsic to pi-subagents (the first 200 lines of
`<repo>/.pi/agent-memory/fleet/MEMORY.md` are injected into each run; worker
appends, reviewer recalls; no Hermes dependency). The fleet memory seed for this
repo is tracked at `.pi/agent-memory/fleet/MEMORY.md`. After a pi-subagents
upgrade, re-diff the shipped definitions against the package builtins. One
JavaScript verifier per pinned package lives under
`workstation/packages/agent/verify/` and checks Pi discovery through the
resource loader.

`pi-skills` verifies managed skill files and discovery through Pi's resource loader.
`pi-ntfy-notifier` deploys from
`workstation/packages/agent/pi-ntfy-notifier/files/.pi/agent/extensions/ntfy-notifier/`
through `workstation apply`, followed by Pi `/reload` or a new process.

Notifier package verification checks manifest/version/files and Node unit tests
that import the extension with a mock Pi API. These do **not** prove actual Pi
auto-discovery or reload cleanup. Real discovery and reload acceptance remains a
separate required check for extension changes: confirm commands/events load once
and shutdown/reload releases owned resources without duplicate handlers. Keep
checks independent of credentials; live notification delivery requires separate
authorization and must not expose tokens.

## Package payload rule

Host-specific or feature-specific payload logic remains under the owning
package as data or package-owned assets — the engine has no per-package code
hooks and never executes package modules:

```text
packages/fonts/files/
packages/languages/node/files/
packages/agent/verify/
```

Everything the engine must know about a package is declared in its native
catalog module (`elixir/apps/core/lib/workstation/core/catalog/packages/`);
anything requiring host execution is expressed as a provisioning recipe the
backend executes, a verify assertion the engine evaluates, or package-owned
payload the host tool consumes.

## Verification requirements

- Verify executable versions through the configured environment.
- Verify tmux with an isolated server/socket.
- Verify fonts through host registration or cache visibility.
- Verify Neovim imports by successful startup.
- Verify languages with real files, parsers, and attached LSP clients.
- Verify formatters by comparing on-disk output.
- Treat directory existence as supporting evidence, not final proof.
