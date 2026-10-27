# Herdr

[Herdr](https://herdr.dev) is a terminal workspace with an upstream-owned
background server. The workstation substrate provisions the pinned binary; it
never manages the runtime.

## Ownership

| Item | Owner |
| --- | --- |
| Binary `0.9.0` (linux x86_64, macOS arm64; WSL uses the Linux asset) | the `herdr` pin declared in `modules/agent/agent.nix` — the checksummed fetchurl derivation lands the exact pinned binary in the store, linked straight to `.local/bin/herdr` |
| Server, panes, sockets, `~/.config/herdr`, sessions, saved machines | Human/host; lifecycle commands never start, stop, attach or inspect them |

The retired Pi integration hook (`herdr-pi`, a file recipe at
`.pi/agent/extensions/herdr-agent-state.ts`) was removed together with the pi
coding agent; Herdr keeps working standalone — the hook retired with pi, not
with Herdr.

## Compatibility gates

Static install is verified automatically. Runtime behavior is
deliberately **not** promised until the corresponding evidence exists (see the
sourced specification, preserved in Git history as `backlog/docs/doc-1`):

| Surface | Status |
| --- | --- |
| Pinned binary + digests (independently re-hashed) | Verified |
| Live server, panes, detach/reattach, native restore | Human-only; start/stop is host-owned |

## Usage notes

- Theme: the substrate documents one canonical choice but never writes herdr's
  live `config.toml` (the binary owns it: onboarding, Settings edits,
  `herdr config reset-keys`). Set once in herdr's Settings:
  `[theme] name = "terminal"`, `auto_switch = true` — herdr then follows the
  host terminal's ANSI palette exactly like the tmux bar here (nvim is the
  one brand-pinned exception: it loads the upstream oasis starlight palette),
  with optional
  `[theme.custom]` accents derived from the shared tokens
  ([theme](theme.md)). Enforcement (a `modify_` fragment patching only the
  `[theme.custom]` block) is a deliberate non-goal until branding is wanted.
- Managed `.local/bin/herdr` shadows any system package (for example an
  Omarchy-provided `/usr/bin/herdr`) through the managed PATH.
- Upgrades: the pin is declared in `modules/agent/agent.nix`; a live server keeps
  running its own version until the human restarts it. Installed bytes and
  running servers are distinct.
