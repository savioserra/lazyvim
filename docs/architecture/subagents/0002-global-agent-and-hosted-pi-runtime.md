# ADR 0002: Global AgentActor lifetime and hosted Pi execution

- **Status:** Accepted
- **Scope:** Agent lifetime, tmux ownership, and per-agent authority binding

## Context

Client sessions and observer views are ephemeral, but an agent may represent long-running work reused by later clients. Hosted execution must preserve a normal Pi TUI without controlling user panes or scraping terminal output. Existing `pi-subagents` runs and the XState tmux observer must retain their current authority.

## Decision

Each `AgentActor` is global and reusable. It outlives credentials, connections, subscriptions, views, and Pi client sessions. Closing or expiring a client removes only that client's grants, opaque handles, projection subscription, and view; it never stops the AgentActor or its work.

A separately typed, explicit hosted-owned registration may give one AgentActor one persistent full Pi TUI/session. The AgentActor owns a `HostedPiRuntimeActor` child and watches it with DeathWatch. The child serializes `inactive`, `starting`, `ready`, `degraded`, `stopping`, and `stopped` state. Tmux, process, filesystem, and bridge effects run asynchronously and report typed completion messages; actor `Receive` handlers do not perform blocking I/O or Ask.

The runtime starts Pi by explicit argv in an exactly owned stable tmux session/window/pane. Pi receives a dedicated persistent session directory and display name, normal resource/package discovery, one explicit repository-managed bridge extension, and an explicit project trust decision. Humans inspect the session with ordinary tmux attach. The service never uses a shell command string, `send-keys`, direct daemon-to-Pi stdin, `respawn-pane`, terminal scraping, or private renderer state.

Tmux ownership is exact: tmux-server PID/start-token, captured stable session/window/pane IDs, human-readable names, pane PID/start-token, and TTY are recorded before readiness. Cleanup and startup rollback each use one tmux client and one server-serialized `if-shell -F` queue that checks the exact marked tuple on that connected server immediately before killing the stable session ID; no reconnect-to-kill occurs. Tests use a separate tmux server name and config and prove a foreign session survives.

Authority is selected once per AgentActor:

1. **Observed upstream:** `pi-subagents` continues to own its execution, worktrees, controls, receipts, recovery, and XState projections. No hosted runtime starts.
2. **Hosted owned:** an explicitly registered new logical agent owns its Pi runtime through the hosted bridge. It is never simultaneously bound to an upstream run.

The repository-managed daemon and `[hosted_pi]` configuration both remain disabled. If separately enabled after review, an owner-private bootstrap credential authenticates bounded START/STATUS/STOP; START creates the session credential/runtime config and returns only nonsecret identity and attach metadata. Merely discovering the global bridge extension is inert; only the exact runtime environment opts it into API registration and connection behavior. There is no automatic authority migration or dual-writer period.

## Persistence boundary

The hosted runtime writes one schema-versioned owner-private binding record beneath XDG state by atomic write and directory sync. It contains only the implemented exact runtime identity and process-start proof. An existing record fails startup closed, preventing blind duplication. Successful tmux creation with malformed output retains a partial record and reservation as ownership-indeterminate. A publication error after rename becomes definitive only when the held reservation proves the exact record, atomic exact tmux rollback succeeds, and record removal plus directory sync succeeds. This milestone does not claim automatic stale-record repair, daemon-crash adoption, durable agent command recovery, or full service-state recovery.

## Consequences

Hosted agents can preserve a full interactive Pi session across client disconnects while existing upstream execution remains unchanged. Exact tmux ownership prevents cleanup from damaging unrelated sessions. A daemon restart may require operator reconciliation because the minimal binding record deliberately prevents duplication rather than claiming complete recovery.

## Invariants

- Client/session cleanup cannot stop a global AgentActor or hosted Pi runtime.
- Every hosted runtime has one AgentActor owner, one runtime actor incarnation, and one exact tmux/process identity.
- Observed-upstream and hosted-owned authority bindings are mutually exclusive.
- Bridge readiness is a renewable fenced lease driven by connect/authenticated poll and GoAkt scheduler expiry; stale timers cannot revoke a newer lease.
- Actor message/control mutations use server-validated exactly-one-increasing source sequences scoped independently by authenticated session/generation/principal, target fence, and runtime incarnation. Authorization runs first; each source owns high-water, bounded results, dedupe, active chains, and pending waiters. Cross-source IDs coexist; queue entries retain source scope through another source's replacement or revocation until ACK/expiry. Same-source reconnect preserves scope and explicit replacement creates only that source's new scope after revocation.
- Registration uses ordered Tell/result/compensation. A service-owned placeholder is published before mutation Tell and persistently watches the original outcome plus ordered compensation beyond caller deadlines. Registry-retired exact PIDs atomically replace that placeholder before tracking acknowledgement; shutdown waits unresolved placeholders and queryable/retryable teardown before stopping ActorSystem. Stopped runtime PID retirement precedes retryable session/credential cleanup represented by `cleanup_pending`.
- Bridge APIs derive send/ask authorization and source identity server-side, require current target fences, separate abort/shutdown control capabilities, retain deliveries until typed acknowledgement, and bind event polls to acknowledged TopicActor subscriptions; terminal bytes are not a protocol.
- Ordinary deliveries are notification-only, model tools require explicit targets, and `ask` denotes delivery acknowledgement rather than an LLM answer.
- Hosted execution and the daemon remain explicit opt-ins and disabled in repository-managed configuration.
- No automatic migration changes `pi-subagents` or XState authority.
