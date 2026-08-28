# Subagents roadmap

This file is the canonical delivery roadmap. ADRs in this directory define architectural decisions; `docs/subagents.md` documents current behavior and operation. The approved visual and interaction contract is the [Actor UX design system](ACTOR-UX-DESIGN-SYSTEM.md).

## Status

| Phase | State | Exit gate |
|---|---|---|
| 0. GoAkt foundation | Approved | Global actors, protobuf UDS, fencing, lifecycle, security tests |
| 1. Hosted Pi runtime | Approved | Full Pi TUI in exactly owned tmux; dynamic actor lifecycle; bridge commands/tools |
| 2. Self-hosting client MVP | Live, managed | Normal Pi creates dynamic actors, sends a real prompt, receives the correlated model answer, and delegates a repository task through the owned system |
| 3. Actor-native push stabilization | Current | Hosted bridges use authenticated daemon push frames from watched BridgeSessionActors, reconnect replay starts from last delivery ACK, and periodic polling is compatibility-only |
| 4. Client stabilization | Next | Reproduce/fix same-name restart; use isolated worktrees; complete several real tasks through owned TaskCoordinator/Workflow actors |
| 5. Authority cutover | Deferred | Owned execution parity proven; disable third-party authority without dual writers; retain bounded rollback window |
| 6. Legacy removal | Deferred | Remove `pi-subagents`, old XState/Terminal Kit observer, superseded tests/docs/packages |
| 7. Managed deployment | Live | Reviewed binary provisioning and active systemd-user/LaunchAgent transition; Linux/WSL/macOS validation |
| 8. Tailscale remoting and clustering | In progress | Three-node MagicDNS bootstrap, custom actor/discovery/peers ports, exact Tailscale-only binds, URI-SAN mTLS, quorum 2, no relocation, and physical VPS/macOS evidence |

## Client MVP definition

The owned client lane means the owned system performs real development work through cross-`AgentActor` communication. A smoke test or manually attached TUI alone does not satisfy this gate.

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

1. Exercise the actor-native BridgeSessionActor push path with a real provider-backed self-improvement task and record reconnect/ACK evidence.
2. Drive worker -> reviewer -> QA -> correction through WorkflowActor without PM UI dependence and record evidence-correct progress.
3. Fix any defect found through the client lane, especially immediate same-name recreation after STOP.

## Future ticket: strong workflow templates

[The draft workflow-template specification](WORKFLOW-TEMPLATE-SPEC.md) inventories current canonical fields separately from proposed strict TOML vocabulary, with non-runnable dogfood examples under [`examples/`](examples/). Implementation must validate and materialize a versioned template into an actor-owned workflow run without agent guesswork, pin the resolved version/digest, and fail without side effects when validation or authorization fails.

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
