# ADR 0001: Direct GoAkt domain actors and framework mechanisms

- **Status:** Accepted
- **Scope:** Subagents service milestones 0/1 and later compatible phases

## Context

The service needs reusable agent identities, ephemeral client access, application projections, lifecycle observation, location-transparent routing, retries, and failure handling. GoAkt v4.5.2 already supplies these mechanisms. Parallel PID buses, subscriber maps, dead-letter topics, timers, death registries, or wrapper frameworks would split semantics and defeat the reason for adopting GoAkt.

## Decision

The service is one direct GoAkt `ActorSystem`. `ServiceGuardian`, `SessionCoordinator`, `SessionRegistryActor`, `AgentRegistryActor`, and `AgentActor` are domain actors, not a second actor abstraction. Supervision is lifecycle-only: it restarts failed actors but does not decide domain authorization, authority, retention, or recovery.

Use GoAkt v4.5.2 directly as follows:

| Need | GoAkt mechanism |
| --- | --- |
| Application subscription and projection events | `WithPubSub`, `TopicActor`, `NewSubscribe`, `NewUnsubscribe`, and `NewPublish`; the publish ID and GoAkt retention window provide transport-level duplicate suppression |
| Actor-system lifecycle and dead letters | `ActorSystem.Subscribe`/`Unsubscribe` event stream only; application topics must not carry system events |
| Actor death | `Watch` and `Terminated`; no polling or parallel liveness registry |
| Logical actor lookup and local/remote transparency | authorized `ActorOf`; domain APIs never expose raw PID values |
| Expiration and retry | `ScheduleOnce`/GoAkt scheduler; no timer goroutine per session |
| Failure policy | GoAkt supervisors and directives; domain compensation remains explicit domain state |
| Tests | GoAkt TestKit probes, event-stream subscription, death watch, and real PubSub behavior |
| Optional future backpressured processing | GoAkt Streams, only when a stream topology is actually required |
| Optional future at-least-once actor delivery | GoAkt reliable delivery, only when its acknowledgement/durable-queue semantics match the required guarantee |

Reliable delivery and Streams are not activated in milestone 1. Reliable delivery does not replace durable domain idempotency, and PubSub's bounded message-ID retention does not make a mutation exactly-once.

## Consequences

Application projection fanout follows GoAkt ordering and at-least-once boundaries instead of custom sorted fanout. Topic subscriber identities remain owned by TopicActor. Cluster/remoting can later extend ActorOf and PubSub without replacing domain routing. Framework system events remain observable independently from authorized application data.

## Invariants

- Production enables PubSub; remoting stays inactive, and hosted Pi starts only for an explicit hosted-owned registration while repository configuration remains disabled.
- Authorization completes before ActorOf lookup or Tell/Ask routing.
- No protobuf field contains a GoAkt PID, actor path, serializer, remoting envelope, or system event.
- No actor blocks in `Receive` on `Ask`, filesystem, network, subprocess, or tmux work.
- Bounded-mailbox delivery failure is explicit and retried by scheduled idempotent coordination.
- Domain mutation idempotency is durable-policy state, not delegated to PubSub retention.
