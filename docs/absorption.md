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
| `copy` (1: agent skills) | REFUSED — hot home | the agent domain module (`modules/agent/agent.nix`): `workstation.agent.skills` maps skill names to payload dirs; each skill leaf renders as a store-path `home.file`. The hot-dir law is thereby scoped precisely: HM manages declared skill LEAVES (the agent consumes them read-only; in-place edits are replaced at the next switch — declared truth wins), while the agent's runtime-mutated state stays untracked forever |
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

### The foundation module's sourcing mix (operator ruling 2026-10-22)

Rainfrog leaves the pin set; harlequin and hsql arrive natively —
`python3Packages.harlequin` from nixpkgs via `home.packages` (the
toolchain pattern: no pin, no probe gate), hsql packaged in the same
derivation. The hsql agent skill is provisioned by an activation script
into the hermes skills dir, version-matched to the harlequin
derivation: the skill is runtime-coupled hot state, so it is
activation-managed (the checkout-ensure pattern), not a declared
store-path leaf. Starship and eza move the same way (operator ruling):
the prompt capability dissolves into foundation — `home.packages +=
[pkgs.eza pkgs.starship]`, the eza ls alias, and the starship
init/config rendering alongside the rc fragments; both are already
nixpkgs-native, no fetchurl derivations. The foundation module's final
inventory is the shell rc lane plus fd, fzf, rg, lazygit, tree-sitter,
eza, starship, harlequin + hsql (op lives in secrets; rainfrog
retired) — three shapes: checksummed pins (ripgrep, fd, fzf, lazygit,
tree-sitter via `nix/lib/pins.nix`), nixpkgs packages (harlequin, hsql,
eza, starship), and one activation provision. The download accounting
above loses rainfrog's, eza's and starship's envelopes at the chain's
next golden re-record. Tailscale joins foundation as the fleet
transport (operator ruling): on the system-module legs (NixOS/darwin)
it is `services.tailscale` in the system module; on the standalone-HM
legs the CLI rides `home.packages` and `tailscaled` stays a documented
host-owned prerequisite. Options: `workstation.foundation.tailscale.*`.
The dashboard unit's `After=tailscaled` dependency already exists in
the systemd unit pattern.

## Decisions this design carries

1. **Payload home: co-location — `modules/<domain>/`** — decided, twice
   superseded, final (operator research note 2026-10-22): the domain's
   module file and the payload bytes it deploys live TOGETHER in one
   self-contained directory (decision 6). The module file lands at
   `modules/<domain>/` in chain stage 1 — its final address; the bytes
   join it in the LAST card, renamed directly from
   `workstation/packages/<domain>/<id>/`. No `payload/` folder — the
   word is security/deployment vocabulary, not nix-community convention
   — and no `workstation/` partition. Until then
   `workstation/packages/**` holds payload bytes plus the dying
   manifests.
2. **`workstation/versions.json` is the interim pin inventory.** Through
   the deletion chain nix reads it (`builtins.fromJSON`); no pin is
   duplicated into module literals. At the endgame it retires with the
   bootstrap (operator clarification 2026-10-22): pins move to the
   owning domain's module and flake-input surface (decision 6). The
   change-rules law ("a pin bump moves the pin + its consumer
   together") survives; only the pin's address changes.
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
5. **The eval golden is transition scaffolding, retired with the walker**
   (operator decision 2026-10-22; binding spec: no byte-goldens). It
   guards the two-reader equivalence through the chain — deliberate
   re-records as envelopes leave, no sacred bytes — and then dies with
   the format it pinned. Post-absorption verification is behavioral:
   VM/activation runs, consumer smokes, HM idempotency/rollback;
   structural assertions (counts/topo) may stay as assertions, never
   byte contracts; deliberate output changes need no re-record ritual.
   `tests/goldens` recorded-envelope suites retire with the format they
   pin.
6. **The endgame layout (operator frame, correction and research note,
   2026-10-22): a domain-oriented, nixpkgs-native monorepo with
   co-located domain modules.** Capabilities are the DOMAINS, not the
   tools; the module tree mirrors `workstation/packages/<domain>/<id>/`
   one-to-one, and the canonical shape (stylix, catppuccin/nix,
   home-manager) is co-location: `modules/<domain>/` holds the domain's
   module file AND the bytes it deploys — `modules/editor/{editor.nix,
   nvim/}`, `modules/terminal/{terminal.nix, tmux/, nunchux/}`,
   one directory per language capability under `modules/languages/`
   (its `.nix` beside its bytes) — so adding a capability is adding one
   directory. Options namespaces are domain-level; tools are entries
   within: `workstation.editor.*` renders the nvim profile,
   `workstation.terminal.*` wires tmux and nunchux,
   `workstation.theme.*` the tokens/mesh surface, `workstation.agent.*`
   hermes and herdr (the skills entry is `workstation.agent.skills`).
   Identity rides the same surface: `workstation.host.{name, user,
   homeDirectory, tailscale.fqdn}` — `hosts/<host>/default.nix` is the
   only place identity is written, and tailscale, the dashboard unit
   (its hardcoded `--host vps` becomes `--host ${fqdn}`) and the flake
   keys derive from it.
   Per-tool modules (`nvim.nix`, `tmux.nix`, `nunchux.nix`,
   `hermes.nix`) are never created. The filesystem is the registry — no
   central catalog; the report fold of decision 4 walks this tree.
   Three layers over it: flake inputs framed per domain (each domain
   owns its pin surface; `follows` dedupes the shared nixpkgs/
   home-manager inputs; never traverse inputs), and outputs as the mesh
   surface, locked (binding spec 2026-10-22):
   `homeManagerModules.workstation`, `darwinConfigurations.mac`,
   `homeConfigurations` (the linux leg), `overlays.default` (pin
   overrides only), and the capability outputs consumer flakes take
   (`workstationTheme.lib`, `hermesSkills`). The
   endgame top level: `flake.nix`, `flake.lock`, `modules/`,
   `hosts/{linux,mac}/`, `hermes/`, `tests/`, `docs/`. The
   `workstation/` partition dissolves — the name survives only as the
   flake/product identity; the launcher shim becomes a derivation
   surfaced at `bin/workstation`; `versions.json` and the bootstrap
   retire (decision 2 carries the interim).

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
- `workstation/packages/**` → co-located `modules/<domain>/` (the final
  card; the `workstation/` partition dissolves);
- the eval-golden byte guard (`tests/nix/goldens/eval-report.json`,
  `.github/scripts/eval-goldens.sh`) retires with the walker —
  verification goes behavioral (decision 5).

The engine's survivors: the CLI/TUI shell, the daemon (reads, pubsub, the
`system` domain, `Overlay`, theme), `Core.EngineState`, and the report reader
that replaces the catalog arm.

## The deletion chain

Three cards, serially parent-chained behind this one; every commit runs the
full battery (`sh .github/scripts/check.sh` — golden replay, eval-goldens,
doclint, identity gate, ShellCheck) and substrate-bearing commits add the VM
E2E (`tests/nix`) with retained receipts:

1. **Native substrate lands.** `nix/lib/pins.nix` + the co-located domain
   modules at their final addresses under `modules/` (editor, terminal,
   theme, languages/{elixir,typescript,node,go}, agent, foundation,
   fonts, secrets — decision 6; the payload bytes follow in the last
   card). Capability by capability the manifest dies in the same
   commit that lands its module — the walker
   shrinks under the walker's own feet, the golden re-record names exactly
   the envelopes that left. Closes the profile gap, the template, the
   modify merge, the retire list, the hot-home surfaces, the foundation
   sourcing mix (rainfrog out; harlequin + hsql + eza + starship in;
   prompt dissolved) on the way.
2. **The format retires.** With the last manifest gone: the walker, the
   JSON discovery, the evalReport producer swap + re-record, and the Elixir
   reader plane listed above are deleted; the engine reads the baked report
   only.
3. **Co-location completes + doc final pass.** The payload bytes join
   their modules — `workstation/packages/<domain>/<id>/` renames
   directly into `modules/<domain>/` (all consumers; no `payload/`
   stopping point) — the `versions.json` mise rows, the chezmoi.md →
   home-state rename with link fixes, and the remaining
   manifest-citation sweep.

## Transition truth

The docs state the native law as of the design commit. Until the chain's
last commit, the manifests remain the walker's transitional input — every
doc that still describes them says so in one place, and no doc describes a
post-absorption surface as if it already existed.
