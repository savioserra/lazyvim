# Theme capability

One canonical color source for every workstation surface that renders color.
Owned by `workstation/packages/theme` (`tokens.lua` holds the data,
`init.lua` is the package factory). Re-branding edits exactly one file.

## Layers

Roles are the API, values are data. Consumers reference role names and never
hardcode a color or slot name for a role carried here. Two layers per role:

| Layer | Maps | Consumed by |
| --- | --- | --- |
| `slots` | role → terminal **named** palette slot | surfaces that follow the live terminal palette (tmux2k); appearance-agnostic, zero regeneration on theme switch |
| `palette` | role → concrete color, per appearance (`dark`, `light`) | surfaces that cannot follow the terminal (rendered UI themes, exports) |

Roles: `accent`, `ok`, `warn`, `err`, `chrome` (muted chrome/borders),
`text` (on accent surfaces in the slot layer, primary foreground in the
palette layer), plus `bg` and `muted` in the palette layer. Slot values are
validated against the 16 ANSI names plus `default`; palette values must be
`#rrggbb`.

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
| pi (`~/.pi/agent/themes/workstation-{dark,light}.json`) | `palette` | template recipes; agent requires `theme`; `settings.json` stays pi-owned — select `"workstation-light/workstation-dark"` once via `/settings` |
| herdr | philosophy + `palette` | documented canonical choice only: `[theme] name = "terminal"`, `auto_switch = true` (see [herdr](herdr.md)); the engine never writes herdr's live `config.toml` |
| nvim | — | unchanged: follows the Omarchy desktop theme |
| term_ui (Elixir TUI + daemon) | `palette` | shipped mirror `Workstation.Core.Theme.Tokens` with tests: the daemon `theme.resolve` overlay applies role sets over it (docs/elixir.md, daemon wire), and the CLI TUI theme resolver mirrors the same palette (pinned by `theme_test.exs` "base path mirrors the core tokens palette exactly") |

## Tests

- `tests/theme.test.lua`: token shape, deterministic envelope bytes,
  fail-closed mutation rejection, provider contract, plan/manifest wiring.
- `tests/capabilities.test.lua`: `theme` requires `foundation` (catalog
  discipline: every HOME-writing capability stays a runtime-late dependent);
  `agent` and `tmux` requires drift guards.
- `tests/backend-render.test.lua`: real chezmoi renders both consumers; no
  template syntax survives, palette bytes match the envelope, and derived
  theme names stay pairable (no `/`).
