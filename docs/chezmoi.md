# Chezmoi file backend

Home state is **generated source state**, not a checked-in payload tree. The
public interface is the repo-native `workstation/bin/workstation`, never
chezmoi commands. `workstation/versions.json` owns the backend pin; no
`.chezmoiversion` policy, source-root marker, archive externals or lifecycle
run-after scripts exist. Capabilities declare recipes through
[`provision.chezmoi`/`provision.shell`](capabilities.md#contribution-contract);
the engine validates, composes and renders them to an immutable generation that
chezmoi applies with explicit `--source` and `--destination`.

See [lifecycle phases](capabilities.md#lifecycle-phases) for ordering and
[README](../README.md) for public commands. Authentication, sessions and
provider state remain user-owned.

## Source generation

| Step | Owner | Contract |
| --- | --- | --- |
| Recipe declaration | Owning package | Pure `provision.*` calls; no I/O or target writes |
| Envelope validation | Core | Dense array of `{ provider, spec }`; nonempty provider IDs only |
| Domain validation | Registered provider | Options, kinds, attributes, target safety, asset confinement |
| Composition | `workstation.source` + compositors | Explicit ordering, one attributed output per shared target |
| Conflict detection | `workstation.source` | Duplicate exclusive targets, ancestor/attribute conflicts, removal overlap, engine-state overlap |
| Publication | `workstation.provisioner` | Immutable content-addressed generation under target-private state |
| Rendering | chezmoi backend | Templates and modify programs; the engine never renders template syntax |

Source names are encoded one-way from the logical target and attributes
(`dot_`, `private_`, `executable_`, `exact_`, `symlink_`, `modify_`, `.tmpl`).
Conflicts are keyed on normalized logical targets, never on decoded names.
Repository `AGENTS.md` files are instructions, not payload: no recipe can
declare them, so no ignore policy is needed and a test proves they cannot
deploy.

Shared shell startup files (`.profile`, `.bashrc`, `.zshrc`) compose from
individually owned fragments (`marker` + single-line literal `body`, explicit
`order`). Removing a fragment removes exactly its recorded marker+body block
and preserves unrelated text and other owners; an edited or duplicated owned
block is a conflict, never a guess. Arbitrary whole-body `modify` programs have
no general inverse: their retirement is reported as an unsupported reversal
instead of a claimed removal. Leftover managed shell lines are not inert.

## Engine state, lock and journal

All engine state lives under the destination home's
`.local/state/workstation` tree, never in ambient XDG roots, the source
checkout or Git:

| Path | Purpose |
| --- | --- |
| `generations/<sha256>` | Immutable published source generations; reused only after byte/type/mode reverification |
| `apply.lock` | Fail-closed per-target operation lock (0600, owner metadata) |
| `journal/applied.json` | Last successful generation, owned target fingerprints, fragment records |
| `journal/pending/`, `journal/failed/` | Attempt evidence; no automatic garbage collection |

`apply` and `diff` hold the lock through publication, backend execution and
journal completion. A contending command refuses with the recorded owner
metadata; stale locks are never stolen — inspect the recorded owner and remove
the lock file only as a deliberate operator action. The exact generation path
is passed to the backend, never a mutable pointer. Last-applied metadata is
updated only after backend success; a failed attempt preserves pending/failed
evidence and requires conflict-aware recovery (retrying the same desired
generation converges idempotently; changed generations re-check every
precondition).

Preconditions stop before backend mutation:

- an owned target that changed since the last successful apply is a conflict;
- first adoption of an existing, unrecorded, differing whole file or link is a
  conflict rather than a silent takeover (identical or absent targets are safe);
- backend-rendered (template) targets never adopt unrecorded existing state;
- writes never traverse symlinked ancestors;
- retiring an exclusive leaf requires its recorded type/content/link to still
  match; shared transformed files and containers are never deleted.

`workstation diff` previews **target-home** changes through the backend and can
reveal your own file contents on your terminal; that explicit human preview is
the intended surface, nothing is redacted automatically, and the engine never
persists or forwards home diffs into the journal, Git or model logs.

`workstation plan` previews the attributable change sets: owner, provider,
operation, normalized target, source entry, type/mode/link metadata,
generated-source Git-style patches against the last applied generation, target
preconditions and unsupported reversals. **Patches describe generated chezmoi
source, not arbitrary HOME content.** They are an inspectable review surface,
not mutation authority: home effects are always the backend's, and archive,
npm or setup side effects are explicitly outside source-patch reversibility.
Journal files hold only generated-source data, fingerprints and ownership
metadata (0700 directories, 0600 files) — never home-file bodies or secrets.

## Removal policy

`.chezmoiremove` is generated per plan from the engine policy module's exact
seventeen legacy tombstones plus explicitly declared and reconciled removals.
The guarded real-account service retirement runs before any file deletion;
scratch targets never contact the live user manager (see
[capabilities](capabilities.md#lifecycle-phases)).

## Isolated validation

Public preview: `workstation plan` and `workstation diff`. A file-only
structural probe may invoke the backend directly with an explicit generation,
destination, config, persistent state and cache in isolated roots. Generations
are target-specific (private state and any inlined link destinations derive
from that home), so build the plan in the same environment you render:

```sh
scratch=$(mktemp -d)
mkdir "$scratch/home" "$scratch/config" "$scratch/cache" "$scratch/state" "$scratch/tmp"
printf '{}\n' > "$scratch/config/chezmoi.json"
env -i PATH=/usr/bin:/bin HOME="$scratch/home" WORKSTATION_HOME="$scratch/home" \
  TMPDIR="$scratch/tmp" \
  XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/state" \
  XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
  "$HOME/.local/opt/chezmoi/bin/chezmoi" \
  --source "$scratch/home/.local/state/workstation/generations/<id>" \
  --destination "$scratch/home" \
  --config "$scratch/config/chezmoi.json" --config-format json \
  --cache "$scratch/cache/chezmoi" --persistent-state "$scratch/state/chezmoi.boltdb" \
  --no-pager --no-tty apply --dry-run
```

Audit the full generated source (recipes, modify programs, templates) before
executing a probe; dry-run or `--exclude` alone is not a sandbox. Add the
network denial, deadline and byte-equivalent file-size guard from
[testing](testing.md#offline-source-checks) for bounded Linux checks. Record
the actual backend version: the automated suites render with the trusted
installed backend (2.72.0 at the time of writing), which is evidence for file
semantics only and **not** pinned 2.72.1 lifecycle acceptance. File rendering
is never full lifecycle acceptance. See [real integration](testing.md#real-integration)
for the authorized scratch harness; historical probe/debug receipts remain in
TASK-34 notes and Git.

## Breaking cutover

This is an **operator/parent procedure**, not an automatic migration script.
Do not execute it while agents are working in `/root/lazyvim` or any active
source checkout. Publication and live cutover require separate approval and
platform gates.

1. Inspect `~/.local/share/workstation` and `~/.local/bin/workstation` without
   following unknown links. Determine whether the former is the old deployed
   `apps/`, `lua/`, `packages/`, `versions.json` payload, a real Git clone, or
   user-owned data. Record exact paths, Git HEAD/status if applicable,
   launcher target, ownership and rollback location. Stop on ambiguity; do
   not clone into an existing directory or delete it.
2. After workers stop, back up approved legacy payload/files to a **new, absent,
   operator-chosen sibling path** using a guarded rename. Back up the old
   launcher separately if conflicting. Never recursively remove an engine
   directory, overwrite a backup, or move the active `/root/lazyvim` checkout
   as part of this procedure. User files, secrets and session state are not
   engine cleanup targets.
3. Clone the whole repository into the now-absent destination, or choose
   another absent checkout path. Inspect the clone and pins before running its
   launcher bootstrap. Bootstrap refuses a link to another checkout;
   explicitly back up and remove/repoint only the inspected old link before
   retrying. A matching managed link is left unchanged. Runtime/backend
   bootstrap must succeed first.
4. Review `workstation plan` (change sets, patches, preconditions) and
   `workstation diff`, then approve real apply, sync and verify separately.
   First apply onto a home with existing differing unrecorded whole files
   intentionally conflicts instead of overwriting: inspect and explicitly back
   up or remove such files. Only real-account apply may retire the identified
   owned legacy service before file removal.
5. On failure stop. Preserve logs, checkouts/backups and the engine journal
   (`~/.local/state/workstation`), including pending/failed evidence. To roll
   back the launcher, inspect its current target and replace **only that
   approved link** with the recorded previous target. Restore approved legacy
   paths from their backups only into absent destinations after checking for
   new state; never erase the new clone to make room. Restoring a
   launcher/source does not undo already changed home files, installed tools
   or retired service state: those need reviewed backups and explicit operator
   recovery. No automatic rollback may touch authentication or resume a
   service.

The generated tombstones remove the old temporary bridge only at
`.local/share/workstation/versions.json`, **not** the clone root or its
canonical `workstation/versions.json`. Other legacy engine payload
inspection/cleanup is operator-owned; there is no blanket recursive migration
deletion. Historical Backlog/decision references to the checked-in `chezmoi/`
tree, `.chezmoiroot`, externals and scripts explain the previous layout and
are not current instructions.
