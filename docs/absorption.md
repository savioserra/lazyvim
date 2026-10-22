# The absorption design: manifests retire into native declarations

Operator ruling 2026-10-21 (card t_e82332d1): the workstation package format
is redundant in the endgame — capabilities become native nix/home-manager
declarations; the manifests, the walker's provider-kind translation table and
the engine's reader retire with the format. This document is the design
deliverable that makes the retirement executable: every provider kind mapped
to its native mechanism (the nine refused envelopes included), the payload
home and the ordering story decided, and the deletion chain fixed. It is
design, not code — the tree moves only through the deletion chain, one
battery-green commit at a time.

## The accounting this design retires

The declared surface at the ruling point is pinned by the eval golden
(`tests/nix/goldens/eval-report.json`, byte-guarded by
`.github/scripts/eval-goldens.sh`): 14 manifests carrying 95 envelopes —
86 rendered across eight lanes, 9 refused:

| Lane | Envelopes |
| --- | --- |
| `file` | 29 |
| `symlink` | 14 |
| `tool-binlink` | 12 |
| `download-tree` | 5 |
| `fragment` | 15 |
| `git-checkout` | 6 |
| `nvim-profile` | 4 |
| `nvim-bin-nixpkgs` | 1 |
| `refused` | 9 |

Every number below is read off that golden; the chain's commits re-record it
deliberately as envelopes leave.

## The mapping: every kind's native mechanism

| Kind (count today) | Walker behavior today | Native mechanism post-absorption |
| --- | --- | --- |
| chezmoi `file`/`symlink` (44 plain: 43 rendered + 1 composed into dir claims) | rendered → `home.file` | keep — store-path sources link directly; intra-home links stay `mkOutOfStoreSymlink`; the `../opt/<tool>` bin-link shape dies (a store path links directly, no opt root) |
| `download` (17: 12 binlinks + 5 trees) | rendered → `fetchurl` + unpack `runCommand` | keep the machinery, move the home: the derivation + claim-composition logic re-lands as `nix/lib/pins.nix`, reading native declarations instead of JSON. The probe honesty gate (argv+output template / content member+sha) becomes a BUILD-TIME assertion in the derivation — a wrong pin fails the build, not a host verify |
| shell fragments (15) | rendered → per-owner fragment files + one sourced rc lane, topo-ordered | keep the shape; the order becomes an explicit declared list (id, target, marker, payload path) in the owning module — reviewed in diffs, no derived topo |
| `git` (7: 6 rendered + 1 refused hot-home) | rendered → `fetchGit`-pinned revs | keep for the six plugin checkouts (`nix/lib/pins.nix`); the hot-home checkout's successor is below |
| `nvim-profile` (4) | the lane stages NOTHING — it counts envelopes and overrides `.local/bin/nvim` → nixpkgs neovim | the composition moves into nix (see the gap note below); the bin override stays |
| chezmoi `template` (1) | REFUSED | native text substitution: the module reads the payload template, substitutes the theme slot placeholders (`lib.replaceStrings`) with values extracted from `tokens.lua` (golden-pinned), and renders `home.file.*.text` |
| chezmoi `private`/`exact` (0 today) | REFUSED (engine contract) | retire with the format — `home.file` covers modes natively where a real need reappears; no successor machinery is designed for a zero-occurrence kind |
| `modify` (1: nvim `lazy-lock.json`) | REFUSED | the ONE semantic `home.file` cannot express (targets never byte-compared; runtime-extended). Successor: pinned baseline payload + a `home.activation` merge script that seeds the live lock once per generation and never resets runtime drift — the payload's merge script promoted from engine contract to module implementation |
| `remove` (2) | REFUSED | two native shapes: entries HM owned leave through the generation diff (HM removes dropped `home.file` entries); legacy/foreign paths (both tombstones here predate the substrate) go through a declared retire list — an idempotent activation `rm -f` with a named receipt, dropped after the fleet has switched past it |
| `mise` (2) | REFUSED — deleted in nix land | nixpkgs: elixir/erlang from the beam set, tmux/btop from nixpkgs, carried by `home.packages`. The mise binary pin, its activation fragment and `.config/mise` composition retire; the `versions.json` mise-only rows retire with the lane |
| `copy` (1: agent skills) | REFUSED — hot home | the hermes skills module (`nix/modules/hermes.nix`): `workstation.hermes.skills` maps skill names to payload dirs; each skill leaf renders as a store-path `home.file`. The hot-dir law is thereby scoped precisely: HM manages declared skill LEAVES (the agent consumes them read-only; in-place edits are replaced at the next switch — declared truth wins), while the agent's runtime-mutated state stays untracked forever |
| `git` into `.hermes` (1: the agent checkout) | REFUSED — hot home | `home.activation.ensure-hermes-checkout`: idempotent clone/fetch to the `hermes_agent_git_commit` pin ONLY when the checkout is absent or clean-and-behind — never touching a dirty or runtime-advanced tree. Activation scripts mutate hot state; the file plane never tracks it |
| `chezmoi-data` (1) | REFUSED — engine runtime data | retired: `tokens.lua` is already the canonical byte source; the envelope was its chezmoi-side projection. Nix reads `tokens.lua` directly (extraction, asserted by the eval golden) |

### The nvim-profile gap this design closes

The card's premise that the nvim-profile lane is "proven" is imprecise: the
walker's lane counts the four envelopes and swaps the `nvim` bin, but the
composed `.config/nvim/lua/languages/profile.lua` is engine-side
(`Workstation.Packages.Nvim.Profile` serializes it at plan time) and lands
NOWHERE on the nix legs — the write plane that deployed it is retired, and
the VM E2E asserts only the bin link. Absorption closes the gap natively:
language entries (`lazyvim_extras`, `plugin_module`, mason packages) become
module data, `lib.generators.toLua` composes `profile.lua` in a derivation,
and the E2E grows an assertion for the deployed profile. The behavior cases
(`language_cases`/`formatter_cases`) stay payload data — they feed the verify
lane, not the deployed file.

## Decisions this design carries

1. **Payload home: `workstation/payload/`** — the rename is decided. There
   are no packages post-absorption; "packages" would name a ghost, and
   "payload" is the word the operating contract already uses. The move is
   mechanical and rides the deletion chain's LAST card (consumers: nix
   modules, verify scripts, docs). Until then `workstation/packages/**`
   holds payload bytes plus the dying manifests.
2. **`workstation/versions.json` stays the pin inventory.** Nix reads it
   (`builtins.fromJSON`); no pin is duplicated into module literals. The
   change-rules law ("a pin bump moves versions.json + the consumer
   together") survives unchanged; only the consumer list changes.
3. **Ordering (the requires graph's replacement):**
   - fragment order: the explicit declared list per rc target (above);
   - activation scripts: `lib.hm.sequence` ordering (the retire list runs
     exactly once per generation; the hermes checkout ensure runs before the
     daemon unit wants it);
   - unit sequencing: systemd `After=`/`WantedBy` — the `after` edge's native
     twin (the daemon unit, the `system` domain);
   - everything else: order-free. Store closure has no apply order;
     overlapping trees compose in one derivation (the claim composition),
     which is what the walker's under-dir-claim rule did imperatively.
4. **The engine's read source is the report.** `flake.evalReport` SURVIVES
   with the same shape; the producer swaps from the walker to a fold over the
   native modules (one deliberate golden re-record). `nix/engine.nix` bakes
   the report JSON into the release — release and declared state ship from
   the same flake snapshot, so the daemon's reads are coherent by
   construction. `packageOrder`/package vocabulary renames to
   capability/capabilityOrder at the swap; the dashboard and domains table
   keep working off the report.
5. **The eval golden survives the walker.** It remains the byte guard over
   the declared surface (and, after the swap, over the native fold); only its
   producer changes. `tests/goldens` recorded-envelope suites retire with the
   format they pin.

## The death certificate

Retired by the deletion chain (each row: the commit that lands it is
battery-green before the next starts):

- `nix/manifest-lib.nix` — discovery, the provider-kind table, the refusal
  registry, the lane renderers (its machinery that survives lives in
  `nix/lib/pins.nix` and the modules);
- all 14 `workstation/packages/**/manifest.json` files (capability by
  capability, golden re-record per commit);
- the Elixir reader plane: the catalog's data arm (`Catalog.Discover`,
  `Catalog.Spec`, `Packages.Reader`, `Packages.Loader`), `Core.Graph`,
  `Core.Contracts.*`, `Backends.Chezmoi`, `Core.Policy` (tombstones → the
  retire list), `Packages.Nvim.Profile` + `Core.Platform.Profile`;
- the recorded-envelope goldens under `tests/goldens` that pin the retired
  shapes;
- the chezmoi vocabulary everywhere: docs/capabilities.md and
  docs/chezmoi.md are rewritten to the native-declaration law in the design
  commit; docs/nvim.md, docs/tmux.md, docs/tools.md, docs/index.md and
  README.md follow their owning chain commits;
- `workstation/packages/` → `workstation/payload/` (the final card).

The engine's survivors: the CLI/TUI shell, the daemon (reads, pubsub, the
`system` domain, `Overlay`, theme), `Core.EngineState`, and the report reader
that replaces the catalog arm.

## The deletion chain

Three cards, serially parent-chained behind this one; every commit runs the
full battery (`sh .github/scripts/check.sh` — golden replay, eval-goldens,
doclint, identity gate, ShellCheck) and substrate-bearing commits add the VM
E2E (`tests/nix`) with retained receipts:

1. **Native substrate lands.** `nix/lib/pins.nix` + the per-capability
   modules under `nix/modules/capabilities/` (agent via `hermes.nix`,
   fonts, foundation, go, node, secrets, herdr, theme, nvim + languages,
   tmux, nunchux, prompt, elixir, typescript). Capability by capability the
   manifest dies in the same commit that lands its module — the walker
   shrinks under the walker's own feet, the golden re-record names exactly
   the envelopes that left. Closes the profile gap, the template, the
   modify merge, the retire list and the hot-home surfaces on the way.
2. **The format retires.** With the last manifest gone: the walker, the
   JSON discovery, the evalReport producer swap + re-record, and the Elixir
   reader plane listed above are deleted; the engine reads the baked report
   only.
3. **Payload home + doc final pass.** The `payload/` rename (all consumers),
   the `versions.json` mise rows, the chezmoi.md → home-state rename with
   link fixes, and the remaining manifest-citation sweep.

## Transition truth

The docs state the native law as of the design commit. Until the chain's
last commit, the manifests remain the walker's transitional input — every
doc that still describes them says so in one place, and no doc describes a
post-absorption surface as if it already existed.
