# ADR 0006: Durable AgentActor threads and introspective resumption

- **Status:** Proposed
- **Scope:** TASK-22/TASK-22.1 hosted `AgentActor` model-task durability, scheduling, resumption, introspection, and migration

## Context

ADR 0005 makes actor Ask completion durable at the source and target, but the hosted target still treats prompt work primarily as a current bridge delivery. A later prompt can therefore compete with, obscure, or prematurely complete an earlier incomplete model task unless the target has a durable work identity and scheduler independent of bridge delivery order. Hosted agents need Slack-like durable threads: every admitted model task has its own ordered history, checkpoint, status, completion key, and retry policy, and the actor schedules one active model thread at a time.

## Decision

Each hosted `AgentActor` owns a durable thread scheduler in its own durable state. A thread is the target-authoritative unit of model work. Bridge deliveries remain runtime I/O records; source outbox and target credit remain ADR 0005 admission records; `ActorTaskCompleted` remains the only authoritative completion route back to the source actor.

A hosted model task is complete only after the exact active thread's model turn settles, a separately configured introspection model returns valid structured output for that active thread, and the daemon durably commits the resulting terminal thread transition. Introspection is never allowed to mutate another thread, change the hosted worker model, infer status from liveness, or mark work complete from malformed or low-confidence output.

## Identity

`thread_id` is distinct from every existing actor and bridge identity.

| Value | Authority | TASK-22 meaning |
| --- | --- | --- |
| `request_id` | request origin / transport | Admission correlation only. |
| `dedupe_id` | source mutation scope | Replay/collision identity only. |
| `chain_id` | source/model provenance | Causal chain only; not a thread identity. |
| `task_id` | source `AgentActor` | Source outbox item only. |
| bridge delivery `sequence` | hosted bridge queue | Runtime push/ACK order only. |
| `completion_key` | target/source task completion | Terminal result dedupe only. |
| `thread_id` | target `AgentActor` | Durable model work identity and scheduler key. |

For an externally admitted `ActorTask`, the target derives:

```text
thread_id = base32(sha256(
  "agent-thread-v1" || NUL ||
  target_agent_id || NUL ||
  source_agent_id || NUL ||
  request_id || NUL ||
  dedupe_id || NUL ||
  chain_id || NUL ||
  decimal(source_mutation_sequence) || NUL ||
  hex(payload_digest)
))[0:52]
```

Collision fields are exactly the derivation fields plus `mode`, `required_capability`, `deadline`, `hop_limit`, and `target_home_node` when remoting is enabled. An exact replay returns the retained thread/admission state. Any mismatch for an existing `thread_id` or any reuse of the same source mutation sequence with different derivation fields fails closed as `thread identity collision` before side effects.

`chain_id` must not become `thread_id`: a chain can span multiple actors and follow-up requests, is source-provided, and can be inherited by model tools. Reusing it as identity would allow task B to alias task A. Continuation of an existing thread requires a daemon-issued `continuation_thread_id` bound to the active thread lease; otherwise every new admitted task gets its own `thread_id` even when `chain_id` matches.

## Durable state and migration

Add `DurableAgentThreadSchedulerSchemaV1` to `application/durable.go` and store scheduler state inside the owning `DurableAgentState`. This keeps the initial implementation in `AgentActor`; a later split into `AgentThreadSchedulerActor` must preserve the same record format and durable-before-effect rules.

Required durable fields:

| Record | Contents |
| --- | --- |
| `DurableAgentThread` | schema, `thread_id`, source/target peers, derivation fields, payload digest, deadline, state, turn, active delivery sequence, completion key, retry counts, backoff, checkpoint digest, terminal digest/result, failure class, event cursor, compacted event list. |
| `DurableThreadEvent` | monotonic per-thread sequence, kind, time, delivery sequence, digest, bounded redacted reason. |
| `DurableThreadScheduler` | schema, `agent_id`, epoch, active thread ID, active lease, FIFO queue, resumable queue, waiting set, blocked set, terminal tombstones, round-robin cursor, new-work deficit counter. |

Durable state values:

```text
queued, active, awaiting_agent_end, awaiting_agent_settled,
introspecting, resumable, waiting, blocked, completed, failed, exhausted
```

Migration from current schema is one-way:

1. Stop new hosted prompt admission during startup reconciliation.
2. Read legacy bridge prompt deliveries and task correlations without mutating them.
3. For each retained prompt delivery, derive `thread_id` deterministically from the fields above.
4. Create `active` for the single current prompt delivery, otherwise `queued` in delivery sequence order.
5. Convert retained terminal completions into completed thread tombstones keyed by `completion_key`.
6. Write the new scheduler and thread fields, fsync file and directory, then write a migration marker containing old/new digests.
7. On restart, a committed marker makes threads authoritative. Partial records without the committed marker quarantine fail-closed.

Quarantine conditions include duplicate `thread_id`, more than one active thread, an active thread without matching delivery/correlation, a scheduler queue entry with no retained thread/tombstone, legacy and new records claiming authority without a committed marker, and any collection or record-size bound violation.

## Prompt and checkpoint retention

Raw prompts and answers are not diagnostics or public projection data. They may be retained only in owner-private operational state when required to honor admitted work:

- Source `AgentActor` source outbox retains the bounded raw prompt only until target `ActorTaskAccepted` is durably committed.
- Target runtime bridge delivery retains the bounded prompt or resume prompt until its delivery is ACKed, terminally failed, or deadline-retired.
- `DurableAgentThread` retains payload digests, event digests, bounded redacted reasons, and the latest bounded checkpoint. It does not retain the full worker transcript.
- A resume `next_prompt` produced by introspection is retained only while the thread is `resumable`, `queued`, or actively dispatching that resume turn.
- Completion result bytes remain only in the existing authenticated source completion mailbox/replay path and target terminal/tombstone digest required for dedupe.

Checkpoint text is owner-private, bounded to 4 KiB, and redacted by the introspection schema. Public roster/status/logs must never include checkpoint text, prompt text, answer text, model names, runtime IDs, session IDs, handles, fences, PIDs, TTYs, hostnames, ports, or tmux identifiers.

## Scheduler and fairness

Each hosted `AgentActor` has at most one active model-bearing thread. A writing actor therefore never runs two writing threads concurrently for the same cwd/worktree. Notifications and authorized control deliveries may be delivered independently, but prompt/model work is scheduled by the thread scheduler.

When no active thread exists, scheduling order is:

1. Highest-priority unblocked explicit continuation for the current thread, if any.
2. FIFO new queued work while `new_work_deficit < 2`.
3. Oldest resumable thread whose `backoff_until <= now`.
4. FIFO new queued work if no resumable thread is eligible.
5. Waiting or blocked threads only after typed unblock/wait-satisfied evidence.

After two consecutive new queued tasks, the next eligible resumable thread wins. This bounds starvation while still allowing fresh mailbox work to make progress. Every scheduling decision increments a scheduler epoch and active lease and is persisted before dispatching a bridge delivery.

## Turn settlement identity

The hosted bridge must report settlement with the exact identity:

```text
agent_id, runtime_id, incarnation, pi_session_id,
thread_id, turn, active_delivery_sequence, completion_key,
agent_start_sequence, agent_end_observed, agent_settled_observed
```

`agent_end` records only bounded evidence for the current turn. It is never terminal. `agent_settled` is the only trigger that can move `awaiting_agent_settled -> introspecting`. Duplicate settlement for the same tuple returns the retained result. Stale settlement for a previous thread, turn, delivery sequence, runtime incarnation, or Pi session is rejected before effects. A future or unknown settlement quarantines the bridge binding if it cannot be explained by replay.

## Introspection

### Configuration

The exact managed syntax is a single property in `[hosted_pi]`:

```toml
[hosted_pi]
introspection_model = "provider/model-or-exact-id"
```

Validation rules:

- Required when `[hosted_pi].enabled = true`.
- Non-empty, trim-equal, 1..128 bytes.
- ASCII visible characters only, matching `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$`.
- Values `auto`, `default`, `inherit`, and `worker` are rejected.
- Unknown TOML fields remain rejected by the existing strict decoder.

The daemon passes this value only to the isolated introspection runner. It must not change the hosted worker Pi model, actor-client model, remoting configuration, or public projections.

### Runner isolation

The hosted bridge invokes Pi's documented model/lifecycle API in an isolated non-transcript routine with the configured `introspection_model`. The routine:

- uses no actor tools, no bridge mutation tools, no shell/tmux/process access, and no credentials;
- does not append messages to the hosted worker conversation or session manager;
- receives only the active thread checkpoint, bounded last-turn evidence, allowed schema, and current thread metadata;
- returns only strict JSON to the bridge.

If the installed Pi runtime cannot provide an isolated exact-model invocation, introspection fails closed as `introspection runner unavailable`; it must not fall back to the worker model or worker transcript.

### JSON schema

The runner output must be a single JSON object with no extra keys:

```json
{
  "state": "completed|continue|waiting|blocked",
  "confidence": "low|medium|high",
  "reason_class": "done|needs_more_work|waiting_on_user|waiting_on_external|blocked_by_error",
  "checkpoint": "string <= 4096 bytes",
  "next_prompt": "string <= 4096 bytes",
  "wait_condition": "string <= 1024 bytes",
  "completion_summary": "string <= 2048 bytes"
}
```

Field rules:

- `completed` requires `confidence = high`, `reason_class = done`, non-empty `completion_summary`, and empty `next_prompt`.
- `continue` requires non-empty `next_prompt`, non-empty `checkpoint`, and `reason_class = needs_more_work`.
- `waiting` requires non-empty `wait_condition` and reason class `waiting_on_user` or `waiting_on_external`.
- `blocked` requires non-empty `wait_condition` and `reason_class = blocked_by_error`.
- `low` confidence is never terminal and becomes `blocked` with reason `low confidence introspection` after retries are exhausted.
- Invalid JSON, extra keys, wrong state/class combination, oversize text, control characters, or missing required fields fail closed and retry.

Introspection is authoritative only for this validated classification of the active thread. It is not authoritative for actor identity, deadlines, runtime incarnation, source routing, completion key, capability, or public status.

## Durable-before-effect transitions

Every mutation that changes observable behavior follows this order:

```text
validate message and current lease
mutate in-memory thread/scheduler state
persist through PersistenceSupervisor
receive durable success in AgentActor
then emit exactly the recorded effects
```

Effects include `ActorTaskAccepted`, bridge push, resume prompt dispatch, introspection invocation, `ActorTaskCompleted`, TopicActor projection, status publication, and scheduling the next thread. Persistence failure rolls back to the saved old durable state or quarantines fail-closed; no speculative effect is allowed.

## Completion routing

A completed thread emits exactly one `ActorTaskCompleted` Tell from the target `AgentActor` to the original source `ActorRef` captured during `ActorTask` acceptance. The source actor durably commits the completion before any attached terminal receives a model-visible custom message. Duplicate completion Tells dedupe by `completion_key` and `thread_id`. TopicActor, WebSocket sessions, in-memory waiters, result polling, and `NoSender` are never completion authority.

## Restart, reconnect, and compaction

On daemon restart, the owning actor reconstructs scheduler queues, active lease, retry timers, and pending completion Tells from durable state. If a thread was `active`, `awaiting_agent_end`, or `awaiting_agent_settled`, its unacked bridge delivery is replayed. If it was `introspecting`, the introspection attempt is retried with the same thread/turn tuple. If it was `resumable` and backoff has expired, it re-enters scheduling. If completion Tell was pending, the target redrives it to the original source reference.

Bridge reconnect reuses the exact runtime incarnation and Pi session. It may replay an unacked delivery, but it never creates a new thread. Duplicate prompt delivery for the same `thread_id`, turn, and delivery sequence is idempotent.

Compaction is checkpoint-based. It may remove old per-turn event details after retaining thread ID, derivation fields/digests, state, turn, retry counts, active delivery, checkpoint digest, completion key, terminal digest, and tombstone. Compaction must not remove active, queued, resumable, waiting, or blocked thread identity.

## Limits and backoff

| Limit | Value |
| --- | --- |
| Threads per actor | 256 hard cap |
| Thread events per thread | 128 before compaction |
| Scheduler queue entries | 256 total non-terminal threads |
| Checkpoint | 4 KiB |
| Resume prompt | 4 KiB |
| Introspection output frame | 16 KiB |
| Introspection attempts per turn | 3 |
| Resume attempts per thread | 8 |
| Base backoff | 1 second |
| Max backoff | 5 minutes |
| Thread lifetime | existing task deadline; default durable actor task deadline remains authoritative |

Backoff is exponential with jitter derived from thread ID digest, never from wall-clock randomness that would break deterministic tests. Exhausting introspection attempts marks the thread `blocked` unless its deadline has expired. Exhausting resume attempts marks it `exhausted` and sends a terminal failure completion to the source.

## Compatibility and cutover

- `PromptTaskRequest` and legacy task lifecycle APIs remain compatibility surfaces but route into the same target thread scheduler.
- Existing actor-message clients do not provide `thread_id`; the target derives it.
- New protobuf fields are additive and optional for older clients. Older clients see existing admission/completion responses.
- After one compatibility window, legacy prompt-in-bridge authority is removed; bridge records retain only runtime delivery/ACK/replay while threads own model-task state.
- `chain_id` remains in public/model results as provenance but is documented as non-authoritative for scheduling.

## File-level implementation slices

1. **Contracts:** `services/subagents/api/subagents/v1/subagents.proto`, generated Go/TS, golden fixtures; add optional thread fields and owner-private status frame.
2. **Durable structs:** `services/subagents/internal/application/durable.go`, `messages.go`; add thread/scheduler messages and schema constants.
3. **Store validation:** `services/subagents/internal/state/store.go`; validate bounds, references, migration markers, and quarantine cases.
4. **Config:** `services/subagents/internal/config/config.go`, config tests, managed `private_config.toml.tmpl`; add exact `introspection_model`.
5. **Agent scheduler:** `services/subagents/internal/actors/agent.go`; admit threads, schedule one active prompt, gate completion through introspection, redrive restart work.
6. **Hosted bridge:** `home/dot_pi/private_agent/extensions/hosted-pi-bridge/`; make `PromptTaskCoordinator` thread/turn aware and add isolated introspection validation.
7. **Service routing:** `services/subagents/internal/service/service.go`; route compatibility lifecycle APIs through durable thread state and expose owner-private projection only after commit.
8. **Docs:** `docs/subagents.md`, this roadmap, Actor UX only if owner-private thread status is rendered.

## Test matrix

| Area | Required proof |
| --- | --- |
| Identity | Exact replay returns same `thread_id`; same `chain_id` with different task creates different thread; collision fields reject mismatch. |
| Admission | `ActorTaskAccepted` is sent only after thread/scheduler durable commit. |
| Scheduling | Task B queues while A active; B cannot mutate A; after at most two new tasks an eligible resumable A runs. |
| Settlement | `agent_end` alone never completes; exact `agent_settled` triggers introspection; duplicate/stale settlement is idempotent/rejected. |
| Introspection | Valid `completed` high confidence completes; malformed/extra-key/low-confidence output cannot complete; timeout retries then blocks/fails by policy. |
| Resume | `continue` stores checkpoint/next prompt, backs off, dispatches resume, and eventually completes without operator input. |
| Waiting/blocked | No auto-resume until typed wait-satisfied/unblock evidence. |
| Restart | Active, introspecting, resumable, and pending-completion states recover without duplicate prompts or completions. |
| Compaction | Old events compact while non-terminal identity and checkpoint survive. |
| Reconnect | Bridge replay does not create another thread; duplicate delivery ACK is idempotent. |
| Completion | Target sends one `ActorTaskCompleted`; source disconnect/reconnect renders once. |
| Config | Exact model accepted; empty/default/inherit/worker/control-char/unknown fields rejected. |
| Privacy | Public roster/status/logs redact prompts, answers, checkpoint, model, runtime/session/fence/handle/thread internals. |
| E2E | Fresh hosted runtime proves A incomplete -> B completes -> A resumes and completes across daemon restart, with no polling, pane inspection, or operator reminder. |

## Consequences

Hosted actors gain durable work memory independent of the Pi bridge's current turn. The scheduler can fairly resume incomplete work without conflating it with later mailbox items. Introspection adds a probabilistic model step, but completion remains deterministic because only validated high-confidence output for the exact active thread can trigger a durable terminal transition and the existing `ActorTaskCompleted` route.
