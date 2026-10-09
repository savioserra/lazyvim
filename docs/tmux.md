# tmux reference

| Property | Value |
| --- | --- |
| Hosts | Linux, macOS |
| Main target | `~/.tmux.conf` and `~/.config/tmux/tmux.conf` symlink |
| Status bar | tmux-oasis, upstream `starlight_dark` flavor |
| Package implementation | `packages/terminal/tmux/init.lua` |
| Plugin root | `~/.tmux/plugins/` |

## Core settings

| Setting | Value |
| --- | --- |
| `status-position` | `bottom` |
| `escape-time` | `10` |
| `focus-events` | `on` |
| `mouse` | `on` |
| `default-terminal` | `tmux-256color` |
| `terminal-features[100]` | `xterm-256color:RGB` |
| `@tmux_navigator_disable_when_zoomed` | `1` |
| Window cycling | root `S-Left` / `S-Right` — `previous-window` / `next-window`, no prefix |

Load order:

1. Base tmux settings and plugin declarations.
2. Plugin options, including `@oasis_flavor "starlight_dark"`.
3. `~/.tmux/plugins/tpm/tpm`.

`~/.config/tmux/tmux.conf` is a managed symlink to `~/.tmux.conf` so tmux
versions that load XDG config after the legacy file cannot let distribution or
desktop defaults override the managed theme.

TPM redirects its plugin root to `~/.config/tmux/plugins/` whenever an XDG
`tmux.conf` exists and then silently sources nothing from the managed root, so
`~/.tmux.conf` pins `set-environment -g TMUX_PLUGIN_MANAGER_PATH
'~/.tmux/plugins/'` before starting TPM. The package verify asserts that pin
on an isolated server.

## Plugin pins

| Plugin | Commit |
| --- | --- |
| `tmux-plugins/tpm` | `e261deb1b47614eed3400089ce7197dc68acc4eb` |
| `uhs-robert/tmux-oasis` | `9903964ee8abdddaf08834871f12ccc093a4cbcf` |
| `tmux-plugins/tmux-yank` | `acfd36e4fcba99f8310a7dfb432111c242fe7392` |
| `christoomey/vim-tmux-navigator` | `e41c431a0c7b7388ae7ba341f01a0d217eb3a432` |
| `tmux-plugins/tmux-resurrect` | `cff343cf9e81983d3da0c8562b01616f12e8d548` |
| `datamadsen/nunchux` | `1546eaa980d834c331496ea9d51942be07ea9fdd` (engine-provisioned; see below) |

Pinning rules:

- Keep `@plugin` values as bare `user/repo` for TPM.
- Store exact commits in this table. The four TPM-installed checkouts are
  (re)created by TPM's `prefix + I` and repairable via `workstation apply`'s
  recorded pins; nunchux is the exception — its checkout is
  engine-provisioned by the package's pinned-clone recipe (below), never by
  TPM.
- tmux-oasis's commit + URL are additionally pinned in
  `workstation/versions.json` (`tmux_oasis*` keys) and asserted by the
  package tests.
- Keep the `TMUX_PLUGIN_MANAGER_PATH` pin ahead of the TPM `run-shell`; TPM's
  default path logic alone would select the unmanaged XDG plugin root.
- Update this table with implementation pins.

TPM `user/repo#ref` supports branches/tags, not exact raw commits.

## Nunchux (engine-provisioned launcher)

| Plugin | Commit | Pin inventory |
| --- | --- | --- |
| `datamadsen/nunchux` | `1546eaa980d834c331496ea9d51942be07ea9fdd` (Release 3.1.3) | `versions.json`: `nunchux_git_*` (clone pin), `nunchux_repo_linux_amd64_sha256` (the repo-tracked `bin/nunchux` build), `nunchux_*` release-asset SHA-256s (distribution inventory) |

Nunchux (fzf popup launcher for apps, files and task runners) is ACTIVE:
the `@plugin` pin and the root `C-Space` chord in `.tmux.conf` are live,
and the checkout itself is the first package-wired pinned-clone recipe
(`Workstation.Packages.Nunchux`): `workstation apply` clones
`datamadsen/nunchux` to `~/.tmux/plugins/nunchux` at the exact v3.1.3
commit — detached HEAD verified against the pin, idempotent re-apply
neither fetches nor moves a checkout already at the pin. The recipe made
the interim download-contract pre-seed obsolete: upstream tracks
`bin/nunchux` in the repo (a linux-amd64 build of the same 3.1.3 release,
`nunchux-go 3.1.3`, content-pinned by `nunchux_repo_linux_amd64_sha256`),
and the download contract refuses to overwrite mismatched bytes, so the
release artifact and the checkout could not compose at one path. The
launcher payload lives in the `nunchux` package: the checkout pin, the
slot-templated `~/.config/nunchux/config` target (byte-equal to upstream's
default config, consuming theme slots — [theme](theme.md)), and the
`bin/.platform` marker.

The load-bearing pre-seed is that marker: upstream's `nunchux.tmux`
`ensure_binary` fetches `releases/latest` — unchecksummed, the same
exclusion-class defect as `tmux-fingers` — whenever `bin/.platform` is
missing or names another platform. With the marker present, plugin load
runs the commit-pinned repo binary and never fetches. Host-side pin
assertion: `packages/nunchux/verify/nunchux.sh` (checkout HEAD, binary
content pin, marker; read-only, never executes the binary).

The launch chord is **C-Space, root** (no prefix): `@nunchux-key` is set to
`C-Space` — upstream's own default — and the activation block binds
`bind -n C-Space display-popup …` (exact nunchux.tmux popup command). TPM
sources the plugin through the active `@plugin` pin, so the chord goes
live together with the checkout. Tradeoff: root `C-Space` shadows the
chord for applications inside tmux (e.g. insert-mode completion). Revert
is one line: comment the bind line in `.tmux.conf` and re-apply (fully
retiring the plugin means commenting the `@plugin` pin and removing the
recipe with it).

Never run TPM's `prefix + I` for nunchux: the engine owns the checkout,
and a TPM clone/pull would fight the pin — `workstation apply` re-asserts
it. Migration note for homes carrying the old pre-seed (a `bin/nunchux`
+ `bin/.platform` directory with no checkout): apply fails closed on the
non-checkout directory — remove `~/.tmux/plugins/nunchux` once and
re-apply; fresh homes clone directly.

Compliance flag: upstream ships NO LICENSE file, so the code is
all-rights-reserved by default — running it is a user-owned choice; the
binary bytes ride the commit pin and are never executed by the engine or
the verify lane.

## Excluded plugin

| Plugin | Reason |
| --- | --- |
| `tmux-fingers` | Unchecksummed bootstrap and no Intel macOS executable |

Setup removes stale `~/.tmux/plugins/tmux-fingers` checkouts.

## Status bar (tmux-oasis)

The status bar is the pinned `tmux-oasis` plugin's own six-module layout at
the upstream `starlight_dark` flavor — the look advertised by upstream's
starlight_dark screenshots. `.tmux.conf` sets only the `@plugin` pin and
`set -g @oasis_flavor "starlight_dark"` ahead of TPM init (upstream's README
install pattern); it deliberately sets NO `@thm_*` options — upstream's
`themes/dark/oasis_starlight_dark.conf` is canonical, the same
upstream-truthed relationship as nvim's `oasis.nvim` pin ([theme](theme.md):
our tokens mirror upstream hexes for our own consumers, they do not feed the
bar).

| Surface | Value (upstream defaults) |
| --- | --- |
| Layout | six modules — mode + session on `status-left`, sync + folder + clock on `status-right`, `status-justify left` |
| Status style | `bg=@thm_mantle, fg=@thm_secondary` |
| Dividers | upstream defaults (no custom separators) |
| Panes | `pane-border-status off`, single border lines; `@oasis_dim_inactive on` paints inactive panes `bg=@thm_crust` |
| Modes / menus / popups | upstream message, mode, menu and popup styles (menu/popup behind tmux >= 3.4 guards) |

Recorded tradeoff (ADDENDUM 2, operator permission — drop tmux2k and adopt
the oasis statusline wholesale): tmux2k's slot layer followed the live
terminal palette via tmux named colors (OSC 4 retints restyled the bar
without a reload); the oasis bar uses literal starlight hexes, so terminal
retints no longer reach it and a dark/light switch flips `@oasis_flavor`.
The swap traded live palette-following for the upstream-literal starlight
look. The tokens slot layer stays in [theme](theme.md) for future
consumers; the retired `~/.config/tmux/themes/tmux2k.conf` target carries a
recorded-ownership removal tombstone in the package recipe (already-absent
no-op on homes that never had it).

## Omarchy interactions

Omarchy ships its own tmux configuration in `/usr/share/omarchy/config/tmux/`
and `omarchy-refresh-tmux` copies it onto `~/.config/tmux/tmux.conf` with
`cp -f`. On a managed host that copy follows the XDG symlink and would
overwrite `~/.tmux.conf`. Never run `omarchy-refresh-tmux` or
`omarchy-refresh-config tmux/tmux.conf` here; if Omarchy ever replaces the
file, restore with `workstation apply` and remove any `tmux.conf.bak.*` it left in
`~/.config/tmux/`.

## Verification

- assert each checkout commit;
- assert the XDG symlink target;
- start an isolated tmux socket and server;
- assert session name;
- assert the `uhs-robert/tmux-oasis` `@plugin` pin in `.tmux.conf`;
- assert `@oasis_flavor=starlight_dark` ahead of TPM init;
- assert the `workstation/versions.json` tmux-oasis pin (commit + URL);
- assert the pinned `TMUX_PLUGIN_MANAGER_PATH`;
- kill the isolated server on success or failure.
