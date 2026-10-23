# tmux reference

| Property | Value |
| --- | --- |
| Hosts | Linux, macOS |
| Main target | `~/.tmux.conf` and `~/.config/tmux/tmux.conf` symlink |
| Status bar | tmux2k, upstream `onedark` theme |
| Package implementation | `Workstation.Packages.Tmux` (payload `workstation/packages/terminal/tmux/`) |
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
| `scroll-on-clear` | `off` inside `%if "#{>=:#{version},3.5}"` — the guard keeps the conf parse-safe on tmux releases without the option (pre-3.4); this host's 3.4 has it default-on (aurora mobile-client mitigation) |
| `@tmux2k-theme` | `onedark` |
| `@tmux2k-bg-main` / `@tmux2k-bg-alt` / `@tmux2k-dark-blue` | `default` — the window no-background slots; tmux2k's variable indirection turns them into `bg=default` |
| `@tmux2k-white` | onedark comment gray — inactive window text |
| `@tmux2k-window-list-colors` | `blue dark_blue` — active window = onedark blue text, no background |
| `@tmux2k-window-list-left-sep` / `-right-sep` | empty — the window separator spans style zero characters, so they paint nothing (module segments keep upstream powerline pills) |
| `@tmux2k-right-plugins` | `cpu ram time` — clicking cpu opens btop; ram's popup is pinned to btop too |
| `@tmux2k-time-format` | `%a %H:%M` — no seconds: a seconds clock pins the status bar to a 1Hz re-render, which limited mobile clients render as stacked lines (aurora mobile-client mitigation) |
| Window cycling | root `S-Left` / `S-Right` — `previous-window` / `next-window`, no prefix |

Load order:

1. Base tmux settings and plugin declarations.
2. tmux2k options — theme, right-side plugin list, the btop popup pin and the clock format.
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
| `2KAbhishek/tmux2k` | `d8c5c2924c557835f984dd44eb71315b897bc4f5` |
| `tmux-plugins/tmux-yank` | `acfd36e4fcba99f8310a7dfb432111c242fe7392` |
| `christoomey/vim-tmux-navigator` | `e41c431a0c7b7388ae7ba341f01a0d217eb3a432` |
| `tmux-plugins/tmux-resurrect` | `cff343cf9e81983d3da0c8562b01616f12e8d548` |
| `datamadsen/nunchux` | `1546eaa980d834c331496ea9d51942be07ea9fdd` (engine-provisioned; see below) |

Pinning rules:

- Keep `@plugin` values as bare `user/repo` for TPM.
- Store exact commits in this table. All six checkouts are
  substrate-provisioned pinned clones, never placed by hand: the plugin
  pins live in `workstation/versions.json` (the interim pin inventory —
  `<plugin>_git_commit` / `<plugin>_git_url` rows) and
  `modules/terminal/terminal.nix` fetchGit-freezes each at the recorded
  commit, linking the store checkout under `~/.tmux/plugins/` (tpm first —
  it must exist before the first tmux start, which sources it via the
  `run-shell` at the end of `.tmux.conf`); nunchux rides the same
  inventory (below). TPM sees the pre-installed checkouts and sources
  them without cloning. Never run TPM's `prefix + I`: a TPM clone/pull
  would fight the pins — the next generation switch re-asserts them.
- The plugin rows are asserted by the package tests (the payload seam).
- Keep the `TMUX_PLUGIN_MANAGER_PATH` pin ahead of the TPM `run-shell`; TPM's
  default path logic alone would select the unmanaged XDG plugin root.
- Update this table with implementation pins, and the inventory rows with
  it. Dropping a plugin from the terminal module retires its recorded
  checkout at the next switch: the generation simply stops linking it
  (atomic generations + rollback own convergence).

TPM `user/repo#ref` supports branches/tags, not exact raw commits.

## Nunchux (engine-provisioned launcher)

| Plugin | Commit | Pin inventory |
| --- | --- | --- |
| `datamadsen/nunchux` | `1546eaa980d834c331496ea9d51942be07ea9fdd` (Release 3.1.3) | `versions.json`: `nunchux_git_*` (clone pin), `nunchux_repo_linux_amd64_sha256` (the repo-tracked `bin/nunchux` build), `nunchux_*` release-asset SHA-256s (distribution inventory) |

Nunchux (fzf popup launcher for apps, files and task runners) is ACTIVE:
the `@plugin` pin and the root `C-Space` chord in `.tmux.conf` are live,
and the checkout itself is the first package-wired pinned-clone recipe:
a generation switch provisions `datamadsen/nunchux` at
`~/.tmux/plugins/nunchux` at the exact v3.1.3
commit — a store checkout linked at the target, so re-switching neither
fetches nor moves a checkout already at the pin. The recipe made
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
is one line: comment the bind line in `.tmux.conf` and switch (fully
retiring the plugin means commenting the `@plugin` pin and removing the
recipe with it).

Never run TPM's `prefix + I` for nunchux: the substrate owns the checkout,
and a TPM clone/pull would fight the pin — the next generation switch
re-asserts it. Homes carrying the old pre-seed (a `bin/nunchux`
+ `bin/.platform` directory with no checkout): remove
`~/.tmux/plugins/nunchux` once and switch; fresh homes link the store
checkout directly.

Compliance flag: upstream ships NO LICENSE file, so the code is
all-rights-reserved by default — running it is a user-owned choice; the
binary bytes ride the commit pin and are never executed by the engine or
the verify lane.

## Excluded plugin

| Plugin | Reason |
| --- | --- |
| `tmux-fingers` | Unchecksummed bootstrap and no Intel macOS executable |

Setup removes stale `~/.tmux/plugins/tmux-fingers` checkouts.

## Status bar (tmux2k, onedark)

The status bar is the pinned `tmux2k` plugin at the upstream `onedark`
theme, rendered TEXT-ONLY: no segment backgrounds — the terminal's own
background shows through and segments are highlighted by text color alone
(operator decision, 2026-10-14). `.tmux.conf` sets the `@plugin` pin, the
theme, `@tmux2k-show-powerline false` (drops the separator paint), the
no-background color slots (`@tmux2k-bg-main`/`-bg-alt`/`-dark-blue` =
`default`), the per-segment `@tmux2k-*-colors` text pairs (session white,
cwd blue, git green, cpu light-green, ram yellow, time light-blue; window
list: active blue, inactive gray via `@tmux2k-white`), the right-side
plugin list (`cpu ram time` — clicking cpu opens btop, ram's popup is
pinned to btop via `@tmux2k-ram-popup-cmd`) and the clock format ahead of
TPM init. Everything else stays upstream onedark — the accents ARE the
theme; they just stopped painting backgrounds.

Bash 5.x empty-lookahead abort (fixed by the pin move, 2026-10-14): tmux2k's
powerline assembly looks ahead one plugin (`${plugins[$((plugin_index + 1))]}`)
to draw each separator; for the LAST plugin of each side that expansion is
empty, and the old pin's `get_plugin_colors ""` indexed `plugin_colors[]`
with the empty subscript — on bash 5.2 a fatal `plugin_colors: bad array
subscript` (its main.sh line 96) that aborted `main.sh` mid-assembly and left
the status bar empty until `2k.tmux` was re-run (the crash was intermittent;
a re-run could crash once before succeeding). Upstream fixed the class with
an early return on an empty plugin name in `get_plugin_colors` (`55e597e`,
2026-09-15; its caller already falls back to the main background for an empty
lookahead), and the pin moved to upstream HEAD `d8c5c292` — proven on a bash
5.2.21 host: `source-file` + `2k.tmux` twice, status-left/right non-empty both
times. Interim recovery on a home still carrying the old pin is the `2k.tmux`
re-run; the real fix is a switch at the new pin.

Pin-move migration: a pinned clone never moves to a different commit in
place (the pin is the checkout's identity — the walker freezes each commit
as its own store path), so a home carrying the tmux2k checkout at the
retired `07b3228b` pin is re-linked at `d8c5c292` by the next switch; the
old checkout stays on disk only if something outside the generation put it
there — remove it explicitly. Same pattern as the nunchux pre-seed
migration note above.

Live re-theming (experimenting with `@tmux2k-*` options on a running
server): the server keeps every `@<plugin>-*` option ever set — a config
reload sets but never unsets, so experiment leftovers (custom separators,
old palettes) override the new theme's defaults. Unset them explicitly, then
reload in order:

```sh
for opt in $(tmux show-options -g | grep -oE '@<plugin>-[a-z0-9-]+'); do
  tmux set-option -gu "$opt"; done
tmux source-file ~/.tmux.conf
tmux run-shell -b '~/.tmux/plugins/tpm/tpm'        # re-init plugin sourcing
tmux run-shell -b '~/.tmux/plugins/tmux2k/2k.tmux' # re-assemble the bar
```

Never kill the session server to re-theme. When reading assembled bar
content, use the HYPHENATED format vars (`#{status-left}`,
`#{status-right}`); the underscore variants are not tmux format variables —
they render empty and mimic a broken bar, which costs a false debugging
loop. Popups run in tmux's shell: a popup-resolved binary (e.g. btop) must
be on the PATH the activation fragments build, not just on the SSH session's.

Recorded tradeoffs: ADDENDUM 2 dropped tmux2k for the tmux-oasis
starlight_dark statusline (operator permission, 2026-10-12); the aurora
investigation (2026-10-13) reverted it — oasis's seconds clock pinned a 1Hz
status re-render whose scroll-style repaints stacked on limited mobile
clients (Termius/iOS), while tmux2k's `|` separators and HH:MM clock are
narrow-phone-safe. The tokens slot layer stays in [theme](theme.md) for
future consumers; the retired `~/.config/tmux/themes/tmux2k.conf` target
is a declared retire-list tombstone in `modules/terminal/terminal.nix`
(an idempotent activation `rm -f` with a named receipt — already-absent
no-op on homes that never had it).

Mobile-client redraw mitigation (aurora, 2026-10-13): the aurora
investigation reproduced Termius/iOS stacking the powerline bar on re-render
at byte level — tmux 3.7's status re-renders emit heavy scroll-style
repaints (242 EL+CRLF + scroll-region resets per 18s idle vs 66 on tmux 3.4,
same config) that limited mobile clients render as stacked lines instead of
replacing the screen. `.tmux.conf` mitigates: the tmux2k clock format
carries no seconds (`%a %H:%M` — a `%S` format pins a 1Hz re-render on
every client), `scroll-on-clear off` keeps the clear-scrolls-history
repaint out of the picture (wrapped in `%if "#{>=:#{version},3.5}"` so
releases without the option never see it at parse time), and the tmux2k
separator set is single-width (`|`) rather than PUA powerline arrows, which
clients without a nerd font render double-width. Re-enabling seconds or
powerline arrows is a deliberate local choice.

## Omarchy interactions

Retired: the substrate no longer targets Arch/omarchy hosts (operator
ruling 2026-10-22 — the flake targets mac and linux, with WSL counted
under linux). The hazard below is kept as the record of why a foreign
distro's config refreshers must never run on a managed host: omarchy's
`omarchy-refresh-tmux` copies `/usr/share/omarchy/config/tmux/` onto
`~/.config/tmux/tmux.conf` with `cp -f`; on a managed host that copy
follows the XDG symlink and would overwrite `~/.tmux.conf`. If a host
ever carries a distro config refresher again, treat it as the same
hazard: restore by switching (the generation re-links the managed
config) and remove any `tmux.conf.bak.*` left in `~/.config/tmux/`.

## Verification

- assert each engine-provisioned checkout at its pinned commit —
  `packages/tmux/verify/tmux.sh` reads the pin inventory's
  `<plugin>_git_commit` rows and checks every `~/.tmux/plugins/<name>`
  HEAD against its pin (read-only, fails closed on the first mismatch);
- assert the XDG symlink target;
- start an isolated tmux socket and server;
- assert session name;
- assert the `2KAbhishek/tmux2k` `@plugin` pin in `.tmux.conf`;
- assert `@tmux2k-theme=onedark`, the `cpu ram time` right side and the btop popup pin ahead of TPM init;
- assert the `workstation/versions.json` tmux2k pin (commit + URL);
- assert the pinned `TMUX_PLUGIN_MANAGER_PATH`;
- kill the isolated server on success or failure.
