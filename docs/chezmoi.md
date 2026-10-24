# Home state: native declarations

Home state is nix: home-manager links every declared target from store
paths, and `workstation-switch` owns activation and rollback. There is no
chezmoi in this repo — no binary is provisioned, no source grammar is
decoded, nothing executes `chezmoi apply`. The recorded-source grammar and
the engine's `Workstation.Backends.Chezmoi` were the manifest format's file
face; both retire with the format (operator ruling 2026-10-21,
[absorption](absorption.md)). The public interface is the repo-native
`workstation/bin/workstation`, and the write plane is
`workstation-switch`, never a file backend. Authentication, sessions and
provider state remain user-owned.

During the deletion chain the walker still renders the surviving manifests
into the same `home.file` surfaces this document describes; the law below is
the post-absorption shape and the transition is marked where it matters.

## Source generation

| Step | Owner | Contract |
| --- | --- | --- |
| Declaration | `modules/<domain>/<domain>.nix` | Native nix: home.file surfaces, pins, fragments, activation scripts |
| Payload | `workstation/packages/<domain>/<id>/` (→ co-located in `modules/<domain>/`) | Referenced bytes, copied into the store at eval |
| Pin derivation | `nix/lib/pins.nix` | Checksummed fetch, layout/extraction rules, build-time probe gate |
| Claim composition | `nix/lib/pins.nix` | Overlapping dir claims compose into one derivation |
| Deployment | the generation | `home-manager switch` links every target atomically |

Target collisions throw at eval — two capabilities claiming one home target
never silently compose. Repository `AGENTS.md` files are instructions, not
payload: no declaration references them.

## Hot-home scope law

The file plane never tracks a hot home — a directory a running program
mutates between switches (`.hermes`, the agent home). Tracked state there
fights the program's writes. The law is scoped to the program's MUTATED
state; it has two precise carve-outs, both declarative:

- **skill leaves** — `modules/agent/agent.nix` renders managed skill files
  as store-path `home.file` entries. The agent consumes them read-only; an
  in-place edit is replaced at the next switch (declared truth wins).
- **activation scripts** — the checkout ensure and the retire list mutate
  hot state at switch time under explicit guards (clone/fetch only when
  absent or clean-and-behind; `rm -f` of named legacy paths), and the file
  plane still tracks nothing.

Everything else under a hot home — checkout internals, tool stores, pm
closures, profiles, boards, memories, sessions — stays untracked forever.

Shared shell startup files (`.profile`, `.bashrc`, `.bash_profile`,
`.zshrc`) compose from individually owned fragments: the owning module
declares the fragment list (id, target, marker, payload path) and the rc
lane sources them in declared order. Removing a fragment from the list
removes exactly its marker+body block at the next switch; the declared
order IS the shell contract, reviewed in diffs.

Runtime-extended mutable targets (targets a running program rewrites) are
never byte-compared: the nvim plugin lock seeds from its pinned baseline
through an activation merge script and stays the editor's between switches.

## Engine state (historical)

The engine state root (the destination home's
`.local/state/workstation` tree, never in ambient XDG roots, the source
checkout or Git) carries only read-side state. The guarded-apply
machinery's files —
`generations/<sha256>` staged source generations, `apply.lock`,
`apply.lock.audit`, `journal/applied.json`,
`journal/pending|failed|retired` —
retired with the write plane; a legacy home may still carry them and the
substrate never reads them. Operator-owned cleanup of those leftovers is
optional and manual; nothing recreates them.

`workstation plan` previews the attributable declared state from the report
(capability, lane, target). The declared-vs-applied diff story is the nix
generation diff (`nix store diff-closures` / `home-manager generations`).
Plan reads never persist or forward home contents into logs.

## Retirement of legacy paths

Two native shapes, both declared:

- entries the file plane owned leave through the generation diff — a
  `home.file` entry dropped from the declarations is removed by the next
  switch;
- legacy/foreign paths (files that predate the substrate or were never
  file-plane-owned) go through the declared retire list: an idempotent
  activation `rm -f` with a named receipt, dropped from the declarations
  after the fleet has switched past it. The manifest-era tombstone
  vocabulary (`kind = "remove"` recipes, `.chezmoiremove` composition,
  `Workstation.Core.Policy`) retires with the format.

The single `.chezmoidata.toml` token envelope retired with the templates:
`packages/theme/tokens.lua` is the canonical token payload, and nix reads
it directly (the extraction asserted at eval, `modules/theme/theme.nix`).

## Isolated validation

`workstation plan` is the public preview (mutates nothing): the daemon
composes the declared surface from the baked report and probes the live
target states — no daemon-side mutation anywhere.

```sh
workstation plan --home <scratch>
```

Reads are daemon-routed and pure (no journal, no filesystem probing beyond
the per-target state report); substrate verification is the VM/activation
harness — see [real integration](testing.md#real-integration). The
recorded-envelope goldens and the eval byte guard retired with the format
(docs/absorption.md — verification is behavioral).

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

Other legacy engine payload inspection/cleanup is operator-owned; there is
no blanket recursive migration deletion. Historical decision references to
the checked-in `chezmoi/` tree, `.chezmoiroot`, externals and scripts
explain the previous layout and are not current instructions.
