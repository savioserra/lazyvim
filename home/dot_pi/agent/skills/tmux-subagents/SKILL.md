---
name: tmux-subagents
description: Opens and controls supervised XState views for managed pi-subagents runs in tmux. Use for automatic windows, prepared-pane attachment, renderer controls, doctor, smoke, or rollback.
---

# Supervise managed subagent views in tmux

`pi-subagents` remains authoritative for execution, sessions, recovery, worktrees, receipts, resume, steer, interrupt, and stop. The extension mirrors that state with XState actors; renderer or pane failure never restarts a managed run.

## Start

1. Run `/tmux-subagents doctor`.
2. Stop if exact `pi-subagents` RPC compatibility, `xstate@5.32.6`, or `terminal-kit@3.1.4` attestation fails.
3. Use a current-session run ID. Do not copy transcript text merely to populate a pane.

## Automatic owned topology

Run `/tmux-subagents open <run-id> [child-id]`. The extension creates or reuses a dedicated owned window, starts the Terminal Kit renderer automatically, tiles panes deterministically, and focuses the exact pane. It bounds topology at four panes per window and four windows. Only a full-tuple-verified view marked `created=true` may be killed.

## Prepared pane

1. Run `/tmux-subagents prepare <run-id> [child-id]` in the owning Pi session.
2. Run the returned command yourself in the prepared pane.
3. The foreground renderer uses an owner-private, expiring, one-use ticket and returns to the original shell when detached.
4. Never use `send-keys`, `respawn-pane`, or kill an adopted pane.

## Renderer controls

- Arrow keys select visible run/child mirror actors.
- `r` requests an authoritative status refresh.
- `s` sends acknowledged steer text.
- `i` confirms interrupt; `x` confirms stop.
- `u` confirms resume against the exact selected identity and supplies its instruction.
- `q` detaches the view; the managed run continues.

All controls follow `Terminal Kit process → authenticated sequenced IPC → XState actors → documented pi-subagents RPC`. The renderer never imports or controls `pi-subagents` directly.

## Apply and reload boundary

The checked-in extension gate is disabled. After tests and independent review:

1. Run `chezmoi apply`; never edit deployed targets directly.
2. Run `/tmux-subagents reload` and let it return.
3. Start one trivial current-session async run and wait for a terminal receipt.
4. Run `/tmux-subagents smoke` from the new generation.
5. Confirm exact dependency/RPC attestation, authenticated one-use IPC, Terminal Kit rendering, owned topology, and unchanged managed state.

To disable, set `enabled=false`, apply, and reload. `PI_TMUX_SUBAGENTS_DISABLE=1` applies only on startup/reload. Rollback closes exact owned views and leaves all managed runs untouched.

## Safety

- Treat pane, socket, observer, or renderer loss as view loss only.
- Keep tickets, claims, bindings, sockets, and projections owner-only and bounded.
- Reject replayed/out-of-order frames, excessive input, stale generations, symlinks, foreign ownership, and path escapes.
- Use compact projections and receipts for token economy; tmux itself does not reduce model tokens.
