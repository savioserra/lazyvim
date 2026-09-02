# Subagents roadmap

This file is the canonical delivery roadmap. ADRs in this directory define architectural decisions; `docs/subagents.md` documents current behavior and operation. The approved visual and interaction contract is the [Actor UX design system](ACTOR-UX-DESIGN-SYSTEM.md). The canonical implementation-ready bridge/frontend architecture, including Ask completion authority, ACK cursor semantics, HostedPiBridgeActor placement, migration, XState package ownership, and remote E2E evidence, is [ADR 0005](0005-daemon-connected-bridge-and-frontend-projections.md). Durable hosted model-task threads, one-active scheduling, and post-settlement introspection are governed by [ADR 0006](0006-durable-agent-threads-and-introspection.md).

## Status

| Phase | State | Exit gate |
|---|---|---|
| 0. GoAkt foundation | Approved | Global actors, protobuf WebSocket application plane, fencing, lifecycle, security tests |
| 1. Hosted Pi runtime | Approved | Full Pi TUI in exactly owned tmux; dynamic actor lifecycle; bridge commands/tools |
| 2. Self-hosting client MVP | Live, managed | Normal Pi creates dynamic actors, sends a real prompt, receives the correlated model answer, and delegates a repository task through the owned system |
| 3. Actor-native push stabilization | Live, migration hardening | ADR 0005 durable delivery, recovery-safe Ask completion, ACK replay, authenticated roster push, epoch/sequence fencing, and XState client projections are live; retire the remaining migration adapters only after replay parity evidence |
| 4. Client stabilization | Current in parallel | Finish production widget wiring, dynamic actor activity projections, same-name/session reincarnation fixes, and owned WorkflowActor UX through isolated worktrees |
| 5. Authority cutover | Deferred | Owned execution parity proven; disable third-party authority without dual writers; retain bounded rollback window |
| 6. Legacy removal | Deferred | Remove `pi-subagents`, old XState/Terminal Kit observer, superseded tests/docs/packages |
| 7. Managed deployment | Live | Reviewed binary provisioning and active systemd-user/LaunchAgent transition; Linux/WSL/macOS validation |
| 8. Trusted-network remoting and clustering | In progress | Multi-node DNS bootstrap, custom actor/discovery/peers/application ports, exact advertised-address binds, URI-SAN mTLS, quorum 2, no relocation, and physical multi-host evidence |

## Client MVP definition

The owned client lane means the owned system performs real development work through cross-`AgentActor` communication. A smoke test or manually attached TUI alone does not satisfy this gate. Durable model-task resumption is governed by [ADR 0006](0006-durable-agent-threads-and-introspection.md): every hosted prompt task receives a target-authoritative thread ID, one-active-thread scheduling, and exact post-`agent_settled` structured introspection before completion.

The gate requires:

1. A normal source-loaded Pi client dynamically creates a named global `AgentActor`.
2. The actor owns a persistent full Pi TUI in an exactly owned tmux session.
3. The client sends a typed prompt without terminal automation.
4. The hosted bridge invokes documented `sendUserMessage` and correlates `agent_end` to one bounded answer.
5. The requesting Pi receives that answer.
6. A writing actor uses an explicitly assigned worktree with one writer per worktree.
7. The actor survives requester disconnect and can be reattached.

Current managed entry point: restart an ordinary globally discovered `pi`; the `actor_*` model tools and `/actor-*` commands discover the owner-private managed service automatically.

## Next three deliverables

1. Complete `TASK-1.1`: wire the shipped XState render snapshots and responsive Pi TUI widgets into the production actor-client renderers, then pass the non-phase Actor UX acceptance matrix.
2. Complete `TASK-22`: implement ADR 0006 durable AgentActor threads and introspective resumption so incomplete hosted tasks survive later mailbox work, compaction, reconnect, and runtime restart.
3. Complete `TASK-1.3`: drive worker -> reviewer -> QA -> correction and a durable user decision through WorkflowActor without PM UI dependence.

The actor-native Ask path is live. After apply/reload, retained completions 30-32 replayed once in order and a fresh sequence 33 completed automatically with `ACTOR_UI_E2E_OK`. The production follow-through remains tracked under the `TASK-1` initiative; deprecation and parity-gated removal of the legacy Pi packages are `TASK-17` and `TASK-18`. Immediate same-name/session reincarnation and terminal roster hygiene remain independently tracked rather than being hidden inside UI work.

Remote/VPS E2E evidence for phase 8 uses three logical nodes (`node-a`, `node-b`, `node-c`) on an owner-controlled private overlay or disposable VPS/VM network with URI-SAN mTLS and distinct actor/discovery/peers/application ports. Required artifacts are sanitized command transcript, logs, and test output proving remote placement, public roster reconciliation, Tell/Ask, target and origin restart replay, ACK gap replay, stale home-node failure, and no host/port or answer leak on public surfaces.

## Future ticket: strong workflow templates

[The draft workflow-template specification](WORKFLOW-TEMPLATE-SPEC.md) inventories current canonical fields separately from proposed strict TOML vocabulary, with non-runnable dogfood examples under [`examples/`](examples/). Implementation must validate and materialize a versioned template into an actor-owned workflow run without agent guesswork, pin the resolved version/digest, and fail without side effects when validation or authorization fails.

## Client reducer model

The ordinary actor-client extension owns the ADR 0005 frontend reducer implementation. Its root XState machine pins `xstate` exactly to 5.20.2 in package and lockfile and owns deterministic projection tests. It exchanges typed daemon messages, subscribes to `ClientAgentRosterFrame` push, owns reconnect cursors and pending request UI state, and exposes bounded render snapshots to Pi. Daemon-side `AgentActor`, `WorkflowActor`, `BridgeSessionActor`, and session registries remain authoritative for security and durable state; the client reducer is not a second authority or transport-specific cache. `TASK-1.1` now moves the remaining production renderer registrations off the legacy communication-card path and onto those snapshots.

Implementation notes:

- Implement daemon connection, authentication, subscriptions, requests, reconnect, replay, and terminal failures as explicit XState v5 states/events under the actor-client extension.
- Preserve typed protocol identities, fences, lifecycle IDs, completion dedupe keys, and the highest-contiguous delivery ACK cursor in actor-client context.
- Keep human rendering derived from the XState snapshot while model-visible tool content remains complete and machine-actionable.
- Use the same actor abstraction for slash commands, model tools, and future dashboards so UI clients share one reducer contract.
- Do not scrape terminal state or infer productive progress in the client actor; consume daemon actor/workflow projections only.

## Future ticket: actor-backed daemon CLI dashboard

After the self-hosting MVP stabilizes, add a Go daemon CLI in the nested `services/subagents` module using Cobra and a Go TUI framework selected by a later ADR.

The CLI connects through the same typed authenticated daemon protocol and is represented by a daemon-side client/session actor. It can resolve actors, Tell/Ask, subscribe, and receive events like any other authorized actor.

Dashboard scope:

- Realtime actors, hosted runtimes, work queues, current tasks, tests/checks, failures, lifecycle events, and dead letters.
- Commands for list, status, create, attach, send, ask, subscribe, and stop.
- Multiple dashboard clients with reconnect and fencing.
- Read-only default; explicit capabilities are required for mutation.
- GoAkt PubSub/event projections with bounded, redacted state.
- No terminal scraping, `send-keys`, secret display, prompt/output dumps, or raw payload display.

This ticket is not on the MVP critical path.
