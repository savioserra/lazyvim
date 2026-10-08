# Theme capability

One canonical color source for every workstation surface that renders color.
Owned by `workstation/packages/theme` (`tokens.lua` holds the data,
`init.lua` is the package factory). Re-branding edits exactly one file.

Current brand: **Starlight** — the oasis.nvim starlight `@thm_*` palette
(dark) and its `light_3` sibling (light, upstream's default intensity).
Palette values cite those theme tokens; the slot layer rides the matching
starlight ANSI-16 terminal assignment. Judgment calls (chrome/muted split,
`selected_bg`, light `muted`) are pinned in the rebrand spec S-R3.

## Layers

Roles are the API, values are data. Consumers reference role names and never
hardcode a color or slot name for a role carried here. Two layers per role:

| Layer | Maps | Consumed by |
| --- | --- | --- |
| `slots` | role → terminal **named** palette slot | surfaces that follow the live terminal palette (tmux2k); appearance-agnostic, zero regeneration on theme switch |
| `palette` | role → concrete color, per appearance (`dark`, `light`) | surfaces that cannot follow the terminal (rendered UI themes, exports) |

Roles: `accent`, `ok`, `warn`, `err`, `chrome` (muted chrome/borders),
`text` (on accent surfaces in the slot layer, primary foreground in the
palette layer), plus `bg` and `muted` in the palette layer. The btop-grammar
affordance roles complete the set: `shortcut` (key-cap letters in tab strips
and border buttonbars), the `selected_bg`/`selected_fg` pair (selection is
never color-alone), `inactive` (dimmed chrome: inactive tabs, stale rows),
and the `ramp_start`/`ramp_mid`/`ramp_end` trio (magnitude ramp: freshness,
drift age, load). Slot values are validated against the 16 ANSI names plus
`default`; palette values must be `#rrggbb`.

The per-domain panel border roles close the set — one per dashboard domain,
all reusing existing palette hues:

| Role | Domain | Hue (why) |
| --- | --- | --- |
| `border_engine` | engine panel | blue — engine-core forward view (`accent` = `@thm_primary #5badff` family) |
| `border_plan` | plan panel (home + tab) | blue — the planned mutation surface |
| `border_journal` | journal panel | green — health-log semantics (`ok` = `@thm_green #7fcf78` family) |
| `border_status` | status panel (home + tab) | green — health verdicts |
| `border_capabilities` | capabilities panel + browser | yellow — pending-apply caution (`warn` = `@thm_yellow #f0e68c`, doubles as the theme's active-pane border hue) |
| `border_diff` | diff panel (home + tab) | red — the mutation surface (`err` = `@thm_red #ff7979` family) |

They live in both layers (slots + per-appearance palette) and are
overlay-settable like every other palette role; `Tokens.border_roles/0` is
the closed membership list a consumer validates against. Panels outside the
domain set (daemon liveness, host, help, verb overlays) keep `chrome`.

## Distribution

The package contributes one `provision.chezmoi_data` recipe: a single
source-root `.chezmoidata.toml` envelope rendered deterministically from
`tokens.chezmoidata()`. It is generation metadata — staged, hashed in the
manifest, byte-verified — but never a home target. chezmoi merges it into
template data at the top level, so templates read
`{{ .theme.slots.accent }}` and `{{ .theme.palette.dark.accent }}`.

At most one package may declare the envelope; a second declarer fails the
plan.

## Consumers

| Surface | Layer | Mechanism |
| --- | --- | --- |
| tmux (`tmux2k.conf`) | `slots` | `template = true` recipe; tmux requires `theme` |
| tmux (nunchux launcher config, prepared) | `slots` | same `template = true` path; plugin stays dormant until engine download provisioning ([tmux](tmux.md)) |
| pi (`~/.pi/agent/themes/workstation-{dark,light}.json`) | `palette` | template recipes; agent requires `theme`; `settings.json` stays pi-owned — select `"workstation-light/workstation-dark"` once via `/settings` |
| herdr | philosophy + `palette` | documented canonical choice only: `[theme] name = "terminal"`, `auto_switch = true` (see [herdr](herdr.md)); the engine never writes herdr's live `config.toml` |
| nvim | — | unchanged: follows the Omarchy desktop theme |
| term_ui (Elixir TUI + daemon) | `palette` | shipped mirror `Workstation.Core.Theme.Tokens` with tests: the daemon `theme.resolve` overlay applies role sets over it (docs/elixir.md, daemon wire), and the CLI TUI theme resolver mirrors the same palette (pinned by `theme_test.exs` "base path mirrors the core tokens palette exactly") |

## TUI box anatomy note

The TUI's btop-style box anatomy (`Workstation.CLI.TUI.Shell.Box`, hard
contracts in docs/elixir.md "TUI application shell") is role-keyed end to
end. Title islands follow btop's exact construction: the superscript keycap
digit (`Shell.keycap/1`, the btop_draw.cpp:87 superscript table — ⁰ ¹ ² ³
⁴-⁹, clamped 0-9) rides `shortcut`, bold, with no space before the title
word (`┐¹engine┌`, never `┐1 engine ┌`); the title word itself rides
`text` (near-white), bold — btop's global title treatment. Panel borders
are per-domain (`border_*` roles above); box connectors and frames outside
the domain set = `chrome`; buttonbar keycaps = `shortcut`, bold, with their
enabled labels = `text` (disabled = `inactive`); active tab and label
highlights = `accent`; selection = the `selected_bg`/`selected_fg` pair
(never color-alone); de-emphasis = `inactive`; value severity/age = the
`ramp_start`/`ramp_mid`/`ramp_end` trio (journal freshness, drift age).
The plain-digit keycap form exists only as an explicit narrow-TTY opt-in,
never the default. No box painter hardcodes a color, so re-branding stays
a one-file edit in `tokens.lua`.

## Tests

- `elixir/apps/core/test/workstation/core/theme/tokens_test.exs`: parity
  anchor — the mirror's rendered `.chezmoidata.toml` envelope is
  byte-identical to the committed theme goldens fixture, contract values
  match `tokens.lua`, the role set is complete, and every palette role is
  overlay-settable.
- `elixir/apps/cli/test/workstation/cli/tui/theme_test.exs`: the CLI base
  palette mirrors the core tokens exactly; daemon resolutions carry the
  closed role set.
- `elixir/apps/core/test/workstation/golden_generate_test.exs`: the plan
  pipeline regenerates the committed goldens byte-for-byte, so any engine
  edit that forgets the Elixir mirror or the rendered envelope fails the
  drift anchor.
- `mix workstation.goldens` re-records the committed goldens after a
  deliberate token change (regenerate, never patch).
