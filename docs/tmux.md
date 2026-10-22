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
| `@tmux2k-git-popup-cmd` | `lazygit branch` — clicking the git segment opens lazygit branch-focused (see [Status-line clicks](#status-line-clicks)) |
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
  engine-provisioned pinned clones, never placed by hand: the tmux package
  manifest declares tpm, tmux2k, tmux-yank, tmux-resurrect and
  vim-tmux-navigator as pinned git recipes (url + commit + target under
  `~/.tmux/plugins/`, tpm first — it must exist before the first tmux start,
  which sources it via the `run-shell` at the end of `.tmux.conf`), and
  nunchux rides its own package's pinned-clone recipe (below). TPM sees the
  pre-installed checkouts and sources them without cloning. Never run TPM's
  `prefix + I`: a TPM clone/pull would fight the pins — `workstation apply`
  re-asserts them.
- tmux2k's commit + URL are additionally pinned in
  `workstation/versions.json` (`tmux2k*` keys) and asserted by the
  package tests.
- Keep the `TMUX_PLUGIN_MANAGER_PATH` pin ahead of the TPM `run-shell`; TPM's
  default path logic alone would select the unmanaged XDG plugin root.
- Update this table with implementation pins, and the package manifest's
  recipes with it. Dropping a recipe from the manifest retires its recorded
  checkout on the next apply: the engine removes it only when HEAD still
  sits at the recorded pin on a clean tree — a moved HEAD or local changes
  refuse the apply with the divergence named, never deleted silently.

TPM `user/repo#ref` supports branches/tags, not exact raw commits.

## Nunchux (engine-provisioned launcher)

| Plugin | Commit | Pin inventory |
| --- | --- | --- |
| `datamadsen/nunchux` | `1546eaa980d834c331496ea9d51942be07ea9fdd` (Release 3.1.3) | `versions.json`: `nunchux_git_*` (clone pin), `nunchux_repo_linux_amd64_sha256` (the repo-tracked `bin/nunchux` build), `nunchux_*` release-asset SHA-256s (distribution inventory) |

Nunchux (fzf popup launcher for apps, files and task runners) is ACTIVE:
the `@plugin` pin and the root `C-g` chord in `.tmux.conf` are live,
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

The launch chord is **C-g, root** (no prefix): `@nunchux-key` is set to
`C-g`, and the activation block binds `bind -n C-g display-popup …` (exact
nunchux.tmux popup command). TPM sources the plugin through the active
`@plugin` pin, so the chord goes live together with the checkout.

The chord moved off upstream's default **C-Space** on 2026-10-21: tmux's
root C-Space claim intercepted the key ahead of nvim, shadowing blink.cmp's
insert-mode completion trigger (the LazyVim blink extra binds `<C-space>`
to show completion). C-g keeps the no-prefix single-chord shape — upstream
itself names C-g as the canonical root "-" key beside C-Space — is claimed
by no tmux plugin in the managed set, and collides in nvim only with
obscure builtins (`:file` info; a rare insert cursor-motion prefix).
Tradeoff, unchanged in kind: any root chord shadows the key for
applications inside tmux. Revert is one line: comment the bind line in
`.tmux.conf` and re-apply (fully retiring the plugin means commenting the
`@plugin` pin and removing the recipe with it).

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
re-run; the real fix is `workstation apply` at the new pin.

Pin-move migration (apply refuses to move a checkout): the git contract never
moves an existing checkout to a different commit (fail-closed — a checkout is
never overwritten in place), so a home carrying the tmux2k checkout at the
retired `07b3228b` pin gets `refusing to move it to d8c5c292…; remove it
explicitly` on the first apply after this bump. Recovery: remove
`~/.tmux/plugins/tmux2k` once and re-apply; fresh homes clone directly at the
new pin. Same pattern as the nunchux pre-seed migration note above.

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
carries a recorded-ownership removal tombstone in the package recipe
(already-absent no-op on homes that never had it).

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

### Status-line clicks

The pinned tmux2k owns the whole status-line click dispatch. It marks every
module segment (`#[range=user|git]` and siblings — tmux's
`mouse_status_range` format carries the range name on click), binds the
status mouse events itself, and routes a click by range: window-list
entries switch windows, marked segments resolve through the plugin's
`lib/popup_handler.sh` (which reads `@tmux2k-<plugin>-popup-cmd` at click
time), and unmarked areas exit 0 silently. `.tmux.conf` registers the git
segment through that sanctioned hook, so the live behavior is:

- git segment → lazygit, branch panel focused (`@tmux2k-git-popup-cmd
  'lazygit branch'` — lazygit's positional git-arg; operator live test,
  2026-10-22);
- window-list entry → window switch (upstream binding);
- cpu/ram segments → btop popup (the `@tmux2k-ram-popup-cmd` pin and
  popup_handler's first-available chain);
- cwd/folder segment → upstream's cwd popup chain (ranger/yazi/nnn/lf/mc —
  none is fleet-installed, so the popup closes itself instantly: no error
  surfaces, the dispatch runs backgrounded, and tmux state is unchanged);
- unmarked areas (separators, padding) → silent no-op, exit 0.

The payload deliberately does NOT rebind the status mouse events: TPM
sources plugins in the background, so a `.tmux.conf` bind races the theme's
own binding, and winning the race would strand the cpu/ram btop popups. An
earlier hand-applied experiment (retired 2026-10-22) bound
`MouseDown1Status` with a `select-window -t=` fallback for every non-git
click — an unmarked segment has no window under the cursor, so those clicks
exited 1 ("can't find window"); the shipped dispatch never runs
select-window from the status line.

## Omarchy interactions

Omarchy ships its own tmux configuration in `/usr/share/omarchy/config/tmux/`
and `omarchy-refresh-tmux` copies it onto `~/.config/tmux/tmux.conf` with
`cp -f`. On a managed host that copy follows the XDG symlink and would
overwrite `~/.tmux.conf`. Never run `omarchy-refresh-tmux` or
`omarchy-refresh-config tmux/tmux.conf` here; if Omarchy ever replaces the
file, restore with `workstation apply` and remove any `tmux.conf.bak.*` it left in
`~/.config/tmux/`.

## Verification

- assert each engine-provisioned checkout at its pinned commit —
  `packages/tmux/verify/tmux.sh` reads the manifest's git recipes and checks
  every `~/.tmux/plugins/<name>` HEAD against its pin (read-only, fails
  closed on the first mismatch);
- assert the XDG symlink target;
- start an isolated tmux socket and server;
- assert session name;
- assert the `2KAbhishek/tmux2k` `@plugin` pin in `.tmux.conf`;
- assert `@tmux2k-theme=onedark`, the `cpu ram time` right side and the btop popup pin ahead of TPM init;
- assert the `workstation/versions.json` tmux2k pin (commit + URL);
- assert the pinned `TMUX_PLUGIN_MANAGER_PATH`;
- kill the isolated server on success or failure.
