# Home state: native declarations

Home state is nix: home-manager links every declared target from store
paths, and `workstation-switch` owns activation and rollback. The public
interface is the repo-native `bin/workstation`, and the write plane is
`workstation-switch`, never a file backend. Authentication, sessions and
provider state remain user-owned.

## Source generation

| Step | Owner | Contract |
| --- | --- | --- |
| Declaration | `modules/<domain>/<domain>.nix` | Native nix: home.file surfaces, tools (overlay + floors), fragments, activation scripts |
| Payload | `modules/<domain>/` (co-located with the declaring module) | Referenced bytes, copied into the store at eval |
| Fragment lane order | `nix/lib/shell-lane.nix` | The fragments' `order` slots sorted once — the rc files and the report read the same sort; shared/ambiguous slots fail the eval |
| Claim composition | `modules/terminal/terminal.nix` (inline) | Overlapping dir claims compose into one derivation (the `.platform` marker — the one consumer since the pins library retired) |
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
order IS the shell contract, reviewed in diffs. One fragment belongs to
the operator: `workstation.foundation.shell.extras` (default empty)
renders the per-machine lines the operator keeps (the `stty -ixon` class)
as the lane's LAST fragment, declared in the identity file (`shellExtras`)
and re-rendered by every switch — operator preferences hold across applies
by construction, not by leaving them alone.

Runtime-extended mutable targets (targets a running program rewrites) are
never byte-compared: the nvim plugin lock seeds from its pinned baseline
through an activation merge script and stays the editor's between switches.

## The state root

The state root (the destination home's
`.local/state/workstation` tree, never in ambient XDG roots, the source
checkout or Git) carries only read-side state: the switch receipt
(`switch.log`) and the theme token link. Nothing recreates legacy trees.

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
  activation pass with a named receipt per outcome, dropped from the
  declarations after the fleet has switched past it. A string entry is a
  file/symlink tombstone (`rm -f`); a tree carries
  `{ path = "..."; recursive = true; }` — the declaration is the consent,
  and the hook removes exactly the declared path recursively. A directory
  met without the consent is reported with the fix named and skipped,
  never silently forced (the vps cutover, 2026-10-27: the nvm tombstone
  taught the tree-consent shape).

`modules/theme/tokens.lua` is the canonical token payload, and nix reads
it directly (the extraction asserted at eval, `modules/theme/theme.nix`).

## Isolated validation

Reads are pure `nix eval`s over `workstation.report` (the shim wraps them)
and mutate nothing; verification is behavioral — see
[testing](testing.md#real-integration).

## Breaking cutover (historical)

The guarded cutover procedure was written for the retired apply plane; the
record of how the old deployed payload was replaced by a Git clone stays in
Git history. On the substrate, a fresh host switches from the
flake (see [README](../README.md#hosts)); an old
`~/.local/share/workstation` deployed payload is operator-owned cleanup —
inspect it, back it up to a new absent sibling path, never clone into or
delete an ambiguous directory, and stop on ambiguity. User files, secrets
and session state are not substrate cleanup targets, and no automatic rollback
may touch authentication.

Other legacy payload inspection/cleanup is operator-owned; there is no
blanket recursive migration deletion. Old layout references explain the
previous state and are not current instructions.
