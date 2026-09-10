# Herdr

[Herdr](https://herdr.dev) is a terminal workspace with an upstream-owned
background server. The workstation engine provisions the pinned binary and the
official Pi integration hook; it never manages the runtime.

## Ownership

| Item | Owner |
| --- | --- |
| Binary `0.9.0` (linux x86_64, macOS arm64; WSL uses the Linux asset) | `workstation/packages/herdr` setup via `provision.file`, link at `.local/bin/herdr` |
| Official Pi hook (integration revision 8, exact bundled bytes) | `workstation/packages/herdr-pi` file recipe at `.pi/agent/extensions/herdr-agent-state.ts` |
| Server, panes, sockets, `~/.config/herdr`, sessions, saved machines | Human/host; lifecycle commands never start, stop, attach or inspect them |
| Pi sessions, subagent children, artifacts, project-pane bindings | Existing `pi` / `pi-subagents` ownership, unchanged |

`herdr-pi` is a full-stack composition (`pi + herdr + pi-subagents`) by owner
decision; Pi and pi-subagents never require Herdr and stay fully runnable
without it. An unmanaged existing hook file fails closed at apply; takeover is
an explicit operator action.

## Compatibility gates

Static install and Pi discovery are verified automatically. Runtime behavior is
deliberately **not** promised until the corresponding evidence exists (see the
sourced specification in `backlog/docs/doc-1`):

| Surface | Status |
| --- | --- |
| Pinned binary + digests (independently re-hashed) | Verified |
| Official hook bytes + integration revision marker | Verified |
| Pi loader discovery, isolated, inert (no Herdr environment) | Verified |
| Live server, panes, detach/reattach, native restore | Human-only; start/stop is host-owned |
| Semantic busy reporting | **Documented limitation**: the inspected official route has no `herdr:busy` receiver; effects untested upstream |
| Blocked overlay, shutdown/reload authority drain, RPC metadata isolation | Not yet tested; no support claimed |
| Inspector / project panes | Existing pi-subagents functionality, unchanged; closing an inspector never stops children |

Semantic idle never proves all children finished; do not build destructive
cleanup on it.

## Usage notes

- Managed `.local/bin/herdr` shadows any system package (for example an
  Omarchy-provided `/usr/bin/herdr`) through the managed PATH. pi-subagents
  locates the client via `HERDR_BIN` (not `HERDR_BIN_PATH`, which Herdr itself
  sets for pane children) falling back to PATH; `PI_SUBAGENT_PI_BINARY`
  scopes only project-pane/model-probe Pi executable selection, never child
  execution.
- The hook activates only inside a Herdr pane (`HERDR_ENV` + socket + pane id);
  it stays inert in headless, RPC and plain-terminal sessions.
- Upgrades: pins live in `workstation/versions.json` together with the bundled
  hook asset; a live server keeps running its own version until the human
  restarts it. Installed bytes and running servers are distinct.
