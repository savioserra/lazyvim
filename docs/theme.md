# Theme capability

One canonical color source for every workstation surface that renders color.
Owned by `modules/theme/` (`tokens.lua` holds the data payload;
the engine carrier is `Workstation.Core.Theme.Tokens`). Re-branding edits both carriers.

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
| `slots` | role → terminal **named** palette slot | surfaces that follow the live terminal palette (the nunchux launcher config; the slot layer stays for future consumers after the tmux2k retirement); appearance-agnostic, zero regeneration on theme switch |
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
| `border_journal` | reserved (declared; the journal box retired with the write plane) | green — health-log semantics (`ok` = `@thm_green #7fcf78` family) |
| `border_status` | status panel (home + tab) | green — health verdicts |
| `border_capabilities` | capabilities panel + browser | yellow — pending-apply caution (`warn` = `@thm_yellow #f0e68c`, doubles as the theme's active-pane border hue) |
| `border_diff` | reserved (declared; the diff box retired with the write plane) | red — the mutation surface (`err` = `@thm_red #ff7979` family) |

They live in both layers (slots + per-appearance palette) and are
overlay-settable like every other palette role; `Tokens.border_roles/0` is
the closed membership list a consumer validates against. Panels outside the
domain set (daemon liveness, host, help, verb overlays) keep `chrome`.

## Distribution

The token set has no envelope and no render step: `tokens.lua` is the
canonical byte source and nix reads it directly at eval — the fail-closed
line extraction in `modules/theme/theme.nix` (every listed key must exist,
every value must match its layer's shape, the extracted set asserted
non-empty; a restructure the parser cannot read fails the eval, never
renders empty tokens). Template consumers substitute slots natively:
`workstationTheme.lib` (the flake output carrying `renderSlots` +
`assertNoUnresolved`) turns `{{ .theme.slots.<name> }}` references into
extracted values, and a template naming a slot the token set does not
carry fails the eval. One home target IS deployed: the store token path —
`modules/theme/tokens.nix` links the extracted tokens (palette + slots) at
`~/.local/state/workstation/theme.json`, a store symlink the switch
re-points every generation (the switch-time push; consumers read the file
or watch the link, nothing polls).

## Consumers

| Surface | Layer | Mechanism |
| --- | --- | --- |
| tmux (status bar) | — (upstream-truthed) | pinned `tmux2k` at the upstream `onedark` theme; `.tmux.conf` sets no theme color options — upstream's onedark palette is canonical (the tokens palette does not feed the bar). The tmux2k slot template target still carries its removal tombstone from the ADDENDUM 2 swap ([tmux](tmux.md)) |
| nunchux (launcher config) | `slots` | the terminal module renders `.config/nunchux/config` from the payload template by slot substitution (`renderSlots` from the extracted tokens, asserted unresolved-slot-free); the checkout is the fetchGit-pinned store tree ([tmux](tmux.md)) |
| herdr | philosophy (terminal-following) | documented canonical choice only: `[theme] name = "terminal"`, `auto_switch = true` (see [herdr](herdr.md)); herdr tracks the host terminal's live ANSI palette, so under the Starlight rebrand it renders starlight via the terminal theme — the engine never writes herdr's live `config.toml` and ships no herdr colors |
| nvim | upstream pin (`oasis-starlight`) | `lazy-lock.json` pins `uhs-robert/oasis.nvim`; the editor rides the upstream starlight palette tokens.lua cites — not a generated colorscheme (rebrand spec S-R4); starlight wins all hosts, Omarchy import dropped (S-R2) |
| term_ui (Elixir TUI) | `palette` | shipped mirror `Workstation.Core.Theme.Tokens` with tests; the CLI TUI theme resolver resolves the base palette (the daemon `theme.resolve` overlay path retired with the daemon — no overlay state survives outside a switch; the deployed store token path carries the same bytes for file-reading consumers) |

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
`ramp_start`/`ramp_mid`/`ramp_end` trio (severity/age ramps).
The plain-digit keycap form exists only as an explicit narrow-TTY opt-in,
never the default. No box painter hardcodes a color, so re-branding stays
a two-carrier edit: `tokens.lua` and `Workstation.Core.Theme.Tokens`.

## Tests

- `apps/core/test/workstation/core/theme/tokens_test.exs`: the parity
  anchor — the engine carrier carries the same contract values as
  `tokens.lua` and the role set is complete.
- `apps/cli/test/workstation/cli/tui/theme_test.exs`: the CLI base
  palette mirrors the core tokens exactly.
