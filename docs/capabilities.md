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
          -> discovered recipe providers (chezmoi, shared shell,
             nvim-profile) -> deterministic source plan
      -> Workstation.Pipeline (under Core.ApplyLock) / Update.* steps
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
| `Workstation.Core.Source` | Source plan and manifest over the recipe provider contracts (chezmoi dialect via `Workstation.Backends.Chezmoi`, shared shell and pinned downloads — single artifacts and probe-gated archive trees — via `Workstation.Core.Contracts.Shell`/`Download`, managed mise tools via `Workstation.Core.Contracts.Mise`) |
| `Workstation.Pipeline` | The one stage-list fold: preconditions, publish, backend apply, journal record, post-apply verify |
| `Workstation.Core.Provisioner` | Chezmoi backend with an exact generation |
| `Workstation.Core.Policy` | Engine-owned legacy tombstones |
| `Workstation.Core.{Journal,EngineState,ApplyLock}` | Immutable generations, fail-closed private state tree, exclusive apply lock |
| `packages/<name>/` | Package payload assets (`files/`, `dot-*` targets) and data files |
| `packages/theme/tokens.lua` | Canonical theme tokens (DATA: slot/palette layers, per-appearance palettes, consumer choices) — read as bytes, never executed |

## Contribution contract

A package contributes its catalog identity through a **pure-data Elixir
module** under `apps/core/lib/workstation/core/catalog/packages/`
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
asset - structured fragments are the `Workstation.Core.Contracts.Shell` compositor's input
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
├── go [Neovim language toolchain]
├── agent [Hermes Agent provisioned full-stack: pinned git checkout, pinned interpreter, engine launcher; managed skills]
├── herdr [pinned terminal-workspace binary; runtime-optional, no server lifecycle]
├── secrets
├── nvim [requires foundation+node+go; owns base/standard/Go profile intents]
├── tmux [linux,darwin]
└── nunchux [requires foundation+theme; linux — pinned checkout (git recipe) + platform marker + theme-slot config]

nvim
├── typescript [requires node+nvim; owns its plugin module, profile intent and verification]
└── elixir [requires nvim; owns its plugin module, profile intent and verification]
```

| Package | Setup | Sync | Verify | Host support |
| --- | --- | --- | --- | --- |
| `foundation` | The CLI tools the editor surface consumes, each a checksum-gated download-contract archive pin at `.local/opt/<tool>` (ripgrep, fd, fzf, lazygit, tree-sitter, rainfrog — per-platform SHA-256 from `versions.json`; the `release` layout for rg/fd/fzf/tree-sitter/rainfrog, `flat` for lazygit's rootless tarball, `zip` for tree-sitter), each probe-gated (`<tool> --version` carries the pinned version) and surfaced on PATH by a `.local/bin/<tool>` link recipe; plus the mise binary pin, the managed mise fragment and the PATH fragments | — | `download-archive` journal records (probes re-run on claim and on verify) + the link records | All |
| `fonts` | Exact pinned JetBrainsMono Nerd Font tree via the download contract (tar.xz `flat` archive, SHA-256-gated; per-platform `targets`: linux `.local/share/fonts/JetBrainsMonoNerdFont`, darwin `Library/Fonts/JetBrainsMonoNerdFont`); the content probe pins `JetBrainsMonoNerdFont-Regular.ttf` bytes — a data tree with no executable to version; host cache/registration reads the provisioned directory | — | `download-archive` record (the content probe re-runs on claim and on verify) | All |
| `node` | nvm via the download contract (pinned v0.40.4 tarball, exact tree at `.local/opt/nvm`, content probe pins `nvm.sh` bytes) then the pinned Node (tar.xz archive, exact tree at `.local/opt/nvm/versions/node/v<version>`, probe `bin/node --version` = `v{V}`) — declared parent-first so the nested target extracts into the provisioned nvm tree; the rc loader (`.config/shell/nvm.sh`) and `.node-version` recipes unchanged | — | `download-archive` records (both probes re-run on claim and on verify) + NVM and Node version | All |
| `agent` | Hermes Agent provisioned full-stack: the pinned git recipe (`~/.hermes/hermes-agent` at the `hermes_agent_git_commit` pin), the pinned interpreter (`.local/opt/hermes/python` — a checksum-gated `hermes_python` archive pin, the same python-build-standalone release hermes-agent's own `pm/lock.json` carries at the pinned commit), the engine launcher (`.local/opt/hermes/bin/hermes` payload, resolved at run time) surfaced on PATH as `.local/bin/hermes`, and the managed skills at `~/.hermes/skills/secrets` (the retired `lazyvim` skill target carries a recorded-ownership removal tombstone) | — | `packages/agent/verify/hermes.sh` (resources + runtime on every host: checkout HEAD at the pin, managed skill file, pinned interpreter, launcher `--version` consumer smoke; read-only; full-stack or exit 1) | All |
| `go` | Exact pinned toolchain tree via the download contract's archive form (`.local/opt/go` — per-platform SHA-256, member-checked single-root tarball, one root stripped, probe-verified `bin/go version` = `go version go{V}`); go link recipe (`.local/bin/go`) | — | `download-archive` journal record (the probe re-runs on claim and on verify — version drift fails loudly) + the link record | Linux/WSL/macOS |
| `elixir` | `provider: "mise"` tool declarations (erlang 28.5, elixir 1.18.5-otp-27) in `workstation/packages/languages/elixir/manifest.json`; the engine contract (`Workstation.Core.Contracts.Mise`) composes `.config/mise/config.toml` and the managed tool state under the engine state root — no mise payload ships with the package (the mise binary pin and the activation fragment `.config/shell/mise.sh` belong to `foundation`) | — | Own Mason expectations, plugin module and behavior/formatter cases through nvim leaf helpers | All |
| `herdr` | Exact pinned binary via the download contract (`.local/opt/herdr/bin/herdr`, per-platform SHA-256); herdr link recipe | — | Applied-download fingerprint (binary bytes carry the pinned checksum) + the link record; never server/pane/session lifecycle | All |
| `secrets` | Pinned op via the download contract (zip `flat` archive — the `op` + `op.sig` pair — exact tree at `.local/opt/op`, probe `op --version`); op env fragment; op link recipe (`.local/bin/op`) | — | `download-archive` record + the link record; verify only `--version`, never account or vault state | All supported hosts |
| `nvim` | — | Locks and parsers | Startup, locks, mason coverage, base/standard/Go behavior | All |
| `typescript` | — | — | Own Mason expectations, plugin module and behavior/formatter cases through nvim leaf helpers | All |
| `theme` | Single source-root `.chezmoidata.toml` token envelope via `provision.chezmoi_data`; deploys no home target | — | Envelope bytes against the tokens module; requires `foundation` | All |
| `tmux` | Plugin checkout; tmux config/theme/link recipes | — | Commits, server, theme | Linux/macOS |
| `nunchux` | Pinned plugin checkout via the git recipe (`.tmux/plugins/nunchux` at the v3.1.3 commit — carries the repo-tracked launcher binary) plus the `.platform` marker (upstream `ensure_binary` never fetches); theme-slot launcher config | — | `packages/nunchux/verify/nunchux.sh` (checkout HEAD + binary content pin + platform marker; read-only, never executes the binary) | Linux (darwin deferred — linux-only package; the darwin release pin stays recorded in `versions.json`) |

### Go toolchain acquisition

Decision recorded 2026-10-15 (card t_1d7be74b): the Go toolchain is a
download-contract ARCHIVE pin, not a host prerequisite. The documented
layout (`.local/opt/go` exact tree + the `.local/bin/go` link) and the
`versions.json` go pins predate the engine's data-manifest cutover but had
no provisioning path — the link dangled on every fresh host. Extending the
download contract keeps one pinned-artifact seam (https-only fetch, 64-hex
SHA-256 gate, per-platform asset dispatch, staged install, exclusive
target ownership) instead of a second acquisition lane, and honors the
operating-contract law: a package that names a tool ships the tool.

The archive form is domain-neutral data on the pin: `archive` names the
format, `probe` (argv + first-line output template with `{V}`) is the
honesty gate — the tree must prove it is the pinned tool before it
activates, on already-converged hosts the probe skips the fetch entirely,
and the applied record (`type: download-archive`) re-probes on every
verify. Extraction is the bootstrap's discipline: traversal-checked
single-root members, exactly one root stripped, private sibling staging,
one rename into place — serialized by the apply lock the pipeline's caller
already holds, so no second installer lock exists. A tree that does not
carry the pinned version is never overwritten: inspect and remove it
explicitly to re-install (pin bumps included). The pins stay byte-identical
to `versions.json` (`go`, `go_<plat>_url`/`_sha256`); a bump re-records the
generation because the pin descriptor is content-addressed.

### Fresh-host archive provisioning: foundation tools, fonts, op, nvm/Node

Decision recorded 2026-10-15 (card t_cf14f71b, after the audit t_bf0c0acc
found the docs claiming provisioning no source implemented): every tool
class above is a download-contract ARCHIVE pin — none stays a documented
host prerequisite, per the operating-contract law. The seam is the same
one contract the go decision grew; the audit's forbidden outcome (docs
claim, source silent) is closed on all four rows. What the contract
gained, each fail-closed and tested:

* formats `tar.xz` and `zip` join `tar.gz` (the apply-time host tools
  `xz`/`unzip` are named prerequisites — a missing tool is a loud,
  named failure, never a silent fallback);
* the declared `layout` names the root discipline — `release` (default:
  exactly one root; a root directory strips one component, a lone root
  file IS the tree — the fzf/tree-sitter shape) and `flat` (rootless
  top-level members — lazygit, the op pair, the font set — safe because
  the staging directory is always fresh);
* the probe has a second shape, the content probe
  (`{member, sha256}`), for trees that carry no executable at all —
  nvm's checkout and the font directory prove their identity by pinned
  member bytes instead of faking a version line;
* the destination may dispatch per platform (`targets`, the mirror of
  `assets`) — the font lands in `.local/share/fonts` on linux and
  `Library/Fonts` on darwin, and the resolution happens only at the
  apply boundary so a recorded plan stays machine-independent.

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
| `terminal` | `nunchux`, `tmux` |
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

| Phase | Input state | Responsibility |
| --- | --- | --- |
| `bootstrap` | Whole source checkout, shell prerequisites | Install verified pinned runtime/backend, then the engine provisions and verifies the conflict-safe public launcher symlink |
| `plan` | Source declarations and journal | Validate and preview attributable change sets, generated-source patches, target preconditions and unsupported reversals; mutate nothing |
| `diff` | Same desired-state generation as apply | Ensure backend, preview file changes only; no retirement/setup/sync/verify |
| `apply` | Validated plan | Retire owned real-account legacy service (never scratch), retire recorded clones whose recipe the plan dropped (guarded: HEAD at the recorded pin on a clean tree — drift refuses with the divergence named), publish the immutable generation, apply through the backend, refresh Node pin/PATH, setup |
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
`apply` verb sources its confirmation plan from the read-shaped
`apply.plan` — the daemon's own mutation-bound composition (journal
baseline, removal activation, retirements), NOT `plan.run`'s pure
read-mode projection, whose generation is structurally different exactly
when a declared removal activates (first convergence after a state
change). Confirming against the composition the daemon executes keeps the
stale-plan guard a true freshness comparison: it refuses a world that
changed between the confirmation and the locked run, never that
structural divergence. The
client's ensure-daemon spawns a daemon detached from the installed release
when the socket is absent or dead (bounded handshake; `workstation daemon
stop` retires it manually); there is no in-process fallback — a missing
daemon is an operator error, because the apply lock must have exactly one
owner.

The verbs that may replace the installed release (`apply`, `update`,
`bootstrap`) first ask a LIVE daemon to exit gracefully
(`Workstation.CLI.PreReplace`): the daemon runs the installed release in
memory, so a replacement under a surviving beam would keep serving stale
code. The daemon's `daemon.stop` is the graceful contract — after the
reply flushes it DRAINS its in-flight op tasks (bounded; each settling op
releases its own apply lock), removes the socket node (no-follow
owned-socket proof), then halts 0 — and the client waits, bounded (~10s),
for BOTH the socket node's removal and the beam's actual exit before
proceeding (the daemon's OS pid comes from the client's `SO_PEERCRED` read
where the platform provides one — Linux — and otherwise from the
`daemon.stop` wire result, which carries the daemon's own pid since
darwin's `xucred` has no pid field and a dir-owner-proof generation no
kernel read at all; a pid from neither source refuses fail-closed); the
verb's own first call then spawns the fresh daemon on
demand from the current release. A refusal (including a daemon too old to
know `daemon.stop`) or a wedged exit FAILS CLOSED with an explicit error —
the verb never replaces the release under a surviving stale daemon and
never signals the process; killing is only ever the MANUAL stop verb's
escalation ladder. The pre-replace stop composes with the release-refresh
handoff: both share the daemon's pending-stop marker, so a second request
while a stop is pending is a daemon-side no-op.

Long ops stream structured events (`run.started`/`step.started`/
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
take effect: when the engine checkout carries a buildable mix umbrella
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
the op with the `handoff` outcome, and stops itself — the GRACEFUL stop
(drain, socket-node removal, exit 0; see the verb table narrative above),
which the client's pre-replace gate composes with instead of fighting. The
CLIENT observes
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
anchor — the mix umbrella root — for EVERY verb and
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
4. **The managed skills** — `~/.hermes/skills/secrets` (the retired
   `lazyvim` skill target carries a recorded-ownership removal tombstone).

One verifier, `workstation/packages/agent/verify/hermes.sh`, asserts all of
it on every host and ends in the consumer smoke: `hermes --version` through
the PATH entry must succeed — full-stack or exit 1; a missing or broken
runtime is provisioning drift, never a documented state. Beyond the
consumer gate the runtime stays upstream's: `hermes update`'s pm-managed
dependency closure, tool store (`~/.hermes/tools/...`) and gateway are
runtime-extended state the package never freezes — the engine provisions
the interpreter and the entry point exactly as it provisions mise and nvim,
and upstream's own machinery fills its store from its own locks on demand.
Runtime updates go through the engine: bump `hermes_agent_git_commit`, move
the `hermes_python` pins to the release the new commit's `pm/lock.json`
names, remove the checkout explicitly (the git contract never moves a
pinned checkout), re-apply.

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

Everything the engine must know about a package is declared in its native
catalog module (`apps/core/lib/workstation/core/catalog/packages/`);
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
- Verify the agent package's full stack on every host: resources (pinned
  checkout, managed skills) and runtime (pinned interpreter, engine
  launcher) alike, ending in the `hermes --version` consumer smoke — an
  absent or broken runtime is provisioning drift, never a documented state.
- Treat directory existence as supporting evidence, not final proof.
