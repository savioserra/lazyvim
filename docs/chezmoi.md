# Chezmoi recorded-source grammar

The engine's file backend is nix: home-manager links every declared target
from store paths, and `workstation-switch` owns activation and rollback.
Chezmoi survives in this repo as a RECORDED-SOURCE GRAMMAR — the one-way
source-name encoding and envelope shapes the committed goldens carry —
decoded by the engine's read face (`Workstation.Backends.Chezmoi` validation,
`from_recorded`, source-name/entry-mode derivation) and rendered by the
walker into HM declarations. No chezmoi binary is provisioned, and nothing
executes `chezmoi apply`: the backend's apply face retired with the
engine's write plane. The public interface is the repo-native
`workstation/bin/workstation`, never chezmoi commands.

Capabilities declare recipes through
[`provision.chezmoi`/`provision.shell`](capabilities.md#contribution-contract);
the engine validates, composes and reports them (the plan wire's declared
program), and the walker turns the same manifests into `home.file` targets.
See [lifecycle phases](capabilities.md#lifecycle-phases) for ordering and
[README](../README.md) for public commands. Authentication, sessions and
provider state remain user-owned.

## Source generation

| Step | Owner | Contract |
| --- | --- | --- |
| Recipe declaration | Owning package | Pure `provision.*` data; no I/O or target writes |
| Envelope validation | Core | Dense array of `{ provider, spec }`; nonempty provider IDs only |
| Domain validation | Registered provider | Options, kinds, attributes, target safety, asset confinement |
| Composition | `workstation.source` + compositors | Explicit ordering, one attributed output per shared target |
| Conflict detection | `workstation.source` | Duplicate exclusive targets, ancestor/attribute conflicts, removal overlap, engine-state overlap |
| Deployment | nix substrate | The walker renders the envelopes into `home.file` targets; the generation links them |

Source names are encoded one-way from the logical target and attributes
(`dot_`, `private_`, `executable_`, `exact_`, `symlink_`, `modify_`, `.tmpl`).
Conflicts are keyed on normalized logical targets, never on decoded names.
Repository `AGENTS.md` files are instructions, not payload: no recipe can
declare them, so no ignore policy is needed and a test proves they cannot
deploy.

## Hot-home scope law

Composition never derives source state under a hot home — a directory a
running program mutates between switches (`.hermes`, the agent home). Any
tracked state there (source entries, derived ancestor directories,
recorded mtimes) fights the program's writes, so the composition refuses
any recipe whose
target lives under it (`Workstation.Core.Source.Paths.assert_not_hermes_home!/1`,
removals exempt: a tombstone has no source name and no ancestors, so it
dir-tracks nothing). Mutable payloads under a hot home are served by the
copy contract instead: declared copy payloads with no derived
source state (see [capabilities](capabilities.md#hermes-resources)).

Generation ids are content addresses over canonical
JSON: compact bytes with object keys sorted ascending bytewise.
Per-process key-order seeding
never reaches them, so identical content yields identical ids in every
process; the golden suite asserts this across two separate engine processes.

Shared shell startup files (`.profile`, `.bashrc`, `.bash_profile`, `.zshrc`) compose from
individually owned fragments (`marker` + single-line literal `body`, explicit
`order`). Removing a fragment removes exactly its recorded marker+body block
and preserves unrelated text and other owners; an edited or duplicated owned
block is a conflict, never a guess. Arbitrary whole-body `modify` programs have
no general inverse: their retirement is reported as an unsupported reversal
instead of a claimed removal. One whole-body modifier is blessed as an
ownership model rather than an escape hatch: engine-seeded, runtime-extended
mutable targets (the nvim lockfile merge program) deploy through it precisely
because modify targets are never byte-compared; see [nvim](nvim.md).
Leftover managed shell lines are not inert.

## Engine state (historical)

The engine state root (the destination home's
`.local/state/workstation` tree, never in ambient XDG roots, the source
checkout or Git) now carries only read-side state. The guarded-apply
machinery's files —
`generations/<sha256>` staged source generations, `apply.lock`,
`apply.lock.audit`, `journal/applied.json`,
`journal/pending|failed|retired` —
retired with the write plane; a legacy home may still carry them and the
substrate never reads them. Operator-owned cleanup of those leftovers is
optional and manual; nothing recreates them.

`workstation plan` previews the attributable composition: owner, provider,
operation, normalized target, source entry and type/mode/link metadata, and
unsupported reversals. The per-target state report (`target_states`) is the
engine's declared-vs-live review surface; the declared-vs-applied diff story
is the nix generation diff (`nix store diff-closures` /
`home-manager generations`). Plan reads never persist or forward home
contents into logs.

## Removal policy

`.chezmoiremove` is composed per plan from the engine policy module's exact
legacy tombstones plus explicitly declared and reconciled removals.
Every final removal literal is revalidated against active ownership and
engine-private state - static policy aggregation gets no bypass - and removal
literals with glob metacharacters or control bytes are rejected so one owned
target can never expand into several removals. The tombstone travels as
declared data (Policy feeds the plan digest); ACTIVATING a removal is the
substrate's convergence, not an engine act.

The generation carries one more engine-owned source-root file: a single
optional `.chezmoidata.toml` envelope contributed through
`provision.chezmoi_data`. It is staged, hashed in the manifest and
byte-verified like every source file, but it is never a home target: the
template data merge is a recorded envelope story, and the theme capability
owns it (see [theme](theme.md)). At most one package may declare it.

Package `kind = "remove"` recipes declare tombstones against **recorded
ownership**: a declared removal of an absent, never-owned target is a no-op
that never becomes a future tombstone. The reviewed
legacy-policy tombstones are a separate narrow migration mechanism, not a
general removal API.

## Isolated validation

`workstation plan` is the public preview (mutates nothing). The offline
replay path substitutes a recorded golden envelope for the live catalog:

```sh
workstation plan --input tests/goldens/<profile>/input.json --home <scratch>
```

Generations are target-specific (private state and any inlined link
destinations derive from that home), so replay against a scratch home stays
deterministic. The read-depth goldens are byte-compared on every
`sh .github/scripts/check.sh` run; see [real integration](testing.md#real-integration)
for the authorized substrate harness. Historical backend-render probe/debug
receipts (the direct `chezmoi apply --dry-run` probes against isolated
roots) remain in Git history.

## Breaking cutover (historical)

The guarded cutover procedure was written for the retired apply plane; the
record of how the old deployed payload was replaced by a Git clone stays in
Git history. On the substrate, a fresh host switches from the
flake (see [README](../README.md#hosts)); an old
`~/.local/share/workstation` deployed payload is operator-owned cleanup —
inspect it, back it up to a new absent sibling path, never clone into or
delete an ambiguous directory, and stop on ambiguity. User files, secrets
and session state are not engine cleanup targets, and no automatic rollback
may touch authentication.

The generated tombstones remove the old temporary bridge only at
`.local/share/workstation/versions.json`, **not** the clone root or its
canonical `workstation/versions.json`. Other legacy engine payload
inspection/cleanup is operator-owned; there is no blanket recursive migration
deletion. Historical decision references to the checked-in `chezmoi/`
tree, `.chezmoiroot`, externals and scripts explain the previous layout and
are not current instructions.
