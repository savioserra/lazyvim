# ADR 0006: Durable AgentActor threads and introspective resumption

- **Status:** Accepted
- **Scope:** TASK-22/TASK-22.1 hosted `AgentActor` model-task durability, scheduling, settlement evidence, introspection, migration, and compatibility cutover

## Context

ADR 0005 makes actor Ask completion durable at source and target, but a hosted target still treats prompt work primarily as the current bridge delivery. A later prompt must not make the actor forget an earlier incomplete task. Hosted agents therefore need durable Slack-like work threads: every admitted model task has one target-authoritative identity, ordered thread events, an owner-private checkpoint, scheduler state, and exact completion routing.

## Decision

Each hosted `AgentActor` owns a durable thread scheduler in its durable hosted record. A thread is the target-authoritative unit of model work. Bridge deliveries remain transport/runtime I/O records; source outbox and target credit remain ADR 0005 admission records; `ActorTaskCompleted` remains the only authoritative completion route back to the source actor.

A hosted task can complete only after:

1. the bridge ACK for the active delivery commits the worker-turn answer and settlement evidence to the exact active thread;
2. a daemon effect runs isolated introspection for that thread/turn;
3. strict JSON introspection output validates as `completed` with high confidence; and
4. the daemon durably commits the terminal thread transition before sending `ActorTaskCompleted`.

Pi lifecycle events are evidence only. The authoritative active identity is the daemon-issued tuple `(agent_id, runtime_id, incarnation, active_thread_id, scheduler_epoch, active_lease, thread_turn, delivery_sequence)`, plus a bridge-local monotonic run counter reported with lifecycle evidence.

## Identity

`thread_id` is distinct from every existing actor and bridge identity.

| Value | Authority | Meaning |
| --- | --- | --- |
| `request_id` | request origin / transport | Admission correlation only. |
| `dedupe_id` | source mutation scope | Replay/collision identity only. |
| `chain_id` | source/model provenance | Causal chain only; not a thread identity. |
| `task_id` | source `AgentActor` | Source outbox item only. |
| bridge delivery `sequence` | hosted bridge queue | Runtime push/ACK order only. |
| `completion_key` | target/source completion | Terminal result dedupe only. |
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

Collision fields are exactly the derivation fields plus `mode`, `required_capability`, `deadline_unix_millis`, and `hop_limit`. An exact replay returns the retained thread/admission state. Any mismatch for an existing `thread_id`, or any reuse of the same source mutation sequence with different derivation fields, fails closed as `thread identity collision` before side effects.

Identity must not include physical node, DNS name, transport host, or current home-node address. Global logical source and target actor IDs plus each actor's authority binding are topology-neutral and unique. The registry must reject two live actors that claim the same logical `agent_id` under different authority bindings or homes; remoting reconciliation may learn routing location but never changes thread identity.

`chain_id` must not become `thread_id`: a chain can span multiple actors and follow-up requests, is source-provided, and can be inherited by model tools. Continuation of an existing thread requires a daemon-issued `continuation_thread_id` bound to the active lease; otherwise every new admitted task gets its own `thread_id` even when `chain_id` matches.

## Durable state and migration

Initial implementation stores scheduler state inside the owning `DurableAgentState` and bumps hosted records from schema v2 to schema v3. A later split into `AgentThreadSchedulerActor` must preserve this record contract and durable-before-effect rules.

Required durable fields:

| Record | Contents |
| --- | --- |
| `DurableAgentThread` | schema, `thread_id`, source/target peers, derivation fields, payload digest, deadline, state, turn, active delivery sequence, completion key, retry counts, backoff, checkpoint, checkpoint digest, terminal worker answer digest/result, introspection attempt/result digest, failure class, event cursor, compacted event list. |
| `DurableThreadEvent` | monotonic per-thread sequence, kind, time, delivery sequence, bridge run counter, digest, bounded redacted reason. |
| `DurableThreadScheduler` | schema, `agent_id`, epoch, active thread ID, active lease, FIFO queue, resumable queue, waiting set, blocked set, terminal tombstones, round-robin cursor, new-work deficit counter. |

Thread states:

```text
queued, active, awaiting_agent_end, awaiting_agent_settled,
settled, introspecting, resumable, waiting, blocked, completed, failed, exhausted
```

### Clean schema v3 cutover

Schema v2 threadless hosted records are intentionally not migrated. The operator explicitly retires and recreates every hosted runtime/session during deployment, producing clean schema v3 records before prompt admission resumes. A retained v2 record fails closed as unsupported and is quarantined; the daemon never guesses thread identity from incomplete legacy delivery state.

Schema v3 writes continue to use the existing temp-file, rename, file-fsync, and directory-fsync atomic replace. Quarantine conditions include duplicate `thread_id`, more than one active thread, active thread without matching delivery/correlation, scheduler entry with no retained thread/tombstone, invalid v3 references, exceeded per-agent serialized limits, or record size exceeding the existing 1 MiB cap after compaction.

## Prompt, answer, checkpoint, and in-thread result semantics

Raw prompts and answers are owner-private operational state only when required to honor admitted work.

- Source outbox retains the bounded raw prompt only until target `ActorTaskAccepted` durably commits.
- Target bridge delivery retains the bounded prompt or resume prompt until transport ACK, terminal failure, or deadline retirement.
- The active thread persists the worker answer from `BridgeDeliveryAck.bounded_result` as its in-thread `worker_result` and digest before the ACK response is returned. This is the deliverable candidate.
- `ActorTaskCompleted.Terminal.Result` remains the full bounded worker answer. Introspection classifies completeness and may provide a summary, but its summary never replaces the deliverable.
- The target retains the answer owner-privately through terminal commit/redrive until the source actor durably commits `ActorTaskCompleted`; source retention/presentation then follows ADR 0005.
- `DurableAgentThread` retains the latest bounded checkpoint and digest. It does not retain the full worker transcript.
- Resume `next_prompt` is retained only while the thread is `resumable`, `queued`, or actively dispatching that resume turn.

Checkpoint text is owner-private, bounded to 4 KiB, and redacted before storage. Public roster/status/logs must never expose checkpoint text, prompt text, answer text, introspection model, thread internals, runtime/session/fence/handle values, PIDs, TTYs, hostnames, ports, DNS names, or tmux identifiers.

## Scheduler and fairness

The thread scheduler guarantees one active model-bearing thread per hosted `AgentActor`. It does not replace crew/workflow access-mode enforcement across actors or worktrees. Crew/workflow state, typed access mode, and authorization still enforce one writer per cwd/worktree across multiple actors.

When no active thread exists, scheduling order is:

1. highest-priority explicit continuation for the current thread if the continuation token matches the last active lease;
2. FIFO new queued work while `new_work_deficit < 2`;
3. oldest resumable thread whose deterministic backoff has expired;
4. FIFO new queued work if no resumable thread is eligible;
5. waiting or blocked threads only after typed wait-satisfied/unblock evidence.

After two consecutive new queued tasks, the next eligible resumable thread wins. Every scheduling decision increments scheduler epoch and active lease and is persisted before bridge delivery, introspection, completion, projection, or next scheduling effect.

## Bridge ACK and settlement evidence

`BridgeDeliveryAck` remains the highest-contiguous transport ACK mechanism and also carries worker-turn evidence. ACK handling must atomically persist:

- contiguous ACK cursor/gap changes;
- active thread's `worker_result` bytes and digest;
- delivery sequence, thread turn, completion key, and bridge run counter;
- `agent_end`/`agent_settled` evidence flags that match the active lease; and
- transition from `awaiting_agent_settled` to `settled`.

The ACK response and delivery retirement occur only after that persistence succeeds. ACK commit does not complete the task. Completion requires the separate introspection attempt/result transition.

The hosted bridge reports lifecycle evidence with:

```text
agent_id, runtime_id, incarnation, pi_session_id,
thread_id, scheduler_epoch, active_lease,
thread_turn, active_delivery_sequence, completion_key,
bridge_run_counter, agent_end_observed, agent_settled_observed
```

`agent_end` alone never completes. `agent_settled` only proves that a bridge run counter settled; the daemon accepts it only when it matches the current active lease/thread/turn/delivery. Duplicate settlement for the same tuple is idempotent. Stale or future settlement is rejected; unexplained future evidence degrades/quarantines the bridge binding.

## Introspection

### Configuration

The exact managed syntax is a single property in `[hosted_pi]`:

```toml
[hosted_pi]
introspection_model = "provider/model"
```

Validation rules:

- Required when `[hosted_pi].enabled = true`.
- Non-empty, trim-equal, 1..128 bytes.
- Exact provider/model form, matching `^[A-Za-z0-9][A-Za-z0-9._@+-]{0,62}/[A-Za-z0-9][A-Za-z0-9._@+-]{0,62}$`.
- Values `auto`, `default`, `inherit`, and `worker` are rejected.
- Unknown TOML fields remain rejected by the strict decoder.

Provider authentication is Pi-owned. The daemon supplies no provider credentials to introspection, logs no model output, and passes the configured model only to the introspection effect.

### Runner isolation

After settlement evidence is durably committed, the daemon starts a dedicated `hostedpi.IntrospectionRunner` effect. The effect spawns the configured Pi binary in RPC mode with the exact `introspection_model` and these mandatory isolation flags:

```text
--no-session --no-tools --no-extensions --no-prompt-templates
```

The introspection prompt is carried in an RPC `prompt` command over stdin. The effect accepts only documented bounded RPC JSONL frames from stdout, extracts exactly one final assistant text, and then parses that text as the strict introspection JSON object. Provider auth remains inside Pi. The runner is not the worker bridge, not the worker conversation, and not a daemon/actor-plane tool call. No actor-plane, daemon, bridge, tool, shell, tmux, process-control, or filesystem tool is exposed to the introspection model; Pi may read only its owner-private model catalogue and provider-auth configuration, and those values never enter prompt or output. The effect communicates only through its dedicated stdin/stdout RPC pipes.

If Pi cannot provide this exact isolated RPC mode, introspection fails closed as `introspection runner unavailable`; it must not fall back to the worker model, worker transcript, bridge tools, or hosted session context.

### Strict JSON parser and schema

The runner output must be exactly one JSON object with UTF-8 text, no BOM, no markdown fences, no trailing non-whitespace bytes, no duplicate keys at any object level, and no keys beyond the schema. Strings must be valid UTF-8, trim-equal where identifiers/classes are expected, and contain no NUL or control characters except JSON-escaped newline in bounded human text fields. Any field containing credential-like material, paths to credential files, handles, fences, runtime IDs, session IDs, PIDs, TTYs, host/port/DNS identity, or raw prompt delimiters is a policy violation; the attempt fails closed and stores only a redacted failure class.

Required object schema:

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

- `completed` requires `confidence = high`, `reason_class = done`, non-empty `completion_summary`, non-empty checkpoint, and empty `next_prompt`/`wait_condition`.
- `continue` requires non-empty `next_prompt`, non-empty checkpoint, and `reason_class = needs_more_work`.
- `waiting` requires non-empty `wait_condition`, non-empty checkpoint, and reason class `waiting_on_user` or `waiting_on_external`.
- `blocked` requires non-empty `wait_condition`, non-empty checkpoint, and `reason_class = blocked_by_error`.
- `low` confidence is never terminal. `medium` confidence may classify `continue`, `waiting`, or `blocked`, but never `completed`.
- Invalid JSON, duplicate keys, extra keys, wrong state/class combination, oversize text, policy-violating material, or missing required fields fails closed and retries.

Introspection is authoritative only for validated classification of the exact active thread. It is not authoritative for actor identity, topology, deadlines, runtime incarnation, source routing, completion key, capability, worker answer bytes, or public status.

## Durable-before-effect transitions

Every mutation that changes observable behavior follows:

```text
validate message/evidence and active lease
mutate in-memory thread/scheduler state
compact if the v3 record would exceed per-agent serialized caps
persist through PersistenceSupervisor using atomic record replace
receive durable success in AgentActor
then emit exactly the recorded effects
```

Effects include `ActorTaskAccepted`, bridge push, ACK response, delivery retirement, introspection process spawn, resume prompt dispatch, `ActorTaskCompleted`, TopicActor projection, owner-private status publication, and next-thread scheduling. Persistence failure rolls back to the saved old durable state or quarantines fail-closed; no speculative effect is allowed.

## State/effect crash table

| Crash point | Durable outcome | Recovery behavior | Duplicate effect rule |
| --- | --- | --- | --- |
| Before clean cutover completes | Unsupported v2 record or no record | Fail closed; operator retires and recreates the hosted runtime. | No v3 effects emitted. |
| After clean v3 record rename/fsync | Valid v3 record | Threads authoritative. | Record creation is idempotent by actor identity. |
| After thread admission mutate, before save | Old state | Caller sees no accepted durable result or retry gets exact replay from old source outbox. | No `ActorTaskAccepted`. |
| After admission save, before `ActorTaskAccepted` | Thread queued | Redrive acceptance/scheduler from durable state. | Acceptance deduped by task/thread. |
| After delivery save, before bridge push | Active delivery retained | Replay/push after reconnect or scheduler tick. | Delivery deduped by sequence/thread/turn. |
| After worker ACK save, before ACK response | ACK cursor and worker result committed | Duplicate ACK returns retained cursor/result; introspection may start. | ACK response idempotent. |
| After ACK response, before introspection spawn | Thread `settled` | Spawn introspection from durable settled state. | One attempt per persisted attempt ID. |
| During introspection process | Attempt pending | Retry with bounded backoff until attempts exhausted. | Prior stdout ignored unless result save committed. |
| After introspection result save, before completion Tell | Thread completed/resumable/waiting/blocked | Emit recorded completion/resume/status effect. | Completion/resume deduped by thread turn. |
| After completion Tell sent, before source commit | Target pending completion retained | Redrive to original source ref. | Source dedupes by completion key/thread. |
| After source commit, before terminal presentation | Source mailbox retained | Reattach drains and renders once. | Presentation ledger dedupes. |

## Completion routing

A completed thread emits exactly one `ActorTaskCompleted` Tell from the target `AgentActor` to the original source `ActorRef` captured during `ActorTask` acceptance. `Terminal.Result` is the full bounded worker answer committed from the active thread's worker result. The introspection summary may appear only as owner-private metadata/provenance and never replaces `Terminal.Result`. The source actor durably commits the completion before terminal presentation. TopicActor, WebSocket sessions, in-memory waiters, result polling, and `NoSender` are never completion authority.

## Restart, reconnect, and compaction

On daemon restart, the actor reconstructs scheduler queues, active lease, retry timers, settled-but-not-introspected attempts, and pending completion Tells from v3 durable state. `active`, `awaiting_agent_end`, and `awaiting_agent_settled` replay their unacked bridge delivery. `settled` or `introspecting` restarts the introspection attempt using the same thread/turn tuple. `resumable` re-enters scheduling when backoff expires. `waiting` and `blocked` remain inert until typed evidence arrives. Pending completion Tell redrives to the original source reference.

Bridge reconnect reuses exact runtime incarnation and Pi session. It may replay unacked delivery but never creates a new thread. Duplicate prompt delivery for the same `thread_id`, turn, delivery sequence, and bridge run counter is idempotent.

Before every save, the actor compacts thread events/checkpoints if serialized v3 state would exceed soft per-agent caps. Compaction may remove old per-turn event details after retaining thread ID, derivation fields/digests, state, turn, retry counts, active delivery, checkpoint digest, completion key, terminal digest/result, and tombstone. If compaction cannot bring the record under the existing 1 MiB hard limit, the actor rejects new prompt admission and degrades/quarantines rather than dropping non-terminal thread identity.

## Limits and backoff

| Limit | Value |
| --- | --- |
| Threads per actor | 256 hard cap |
| Non-terminal scheduler entries | 256 total |
| Thread events per thread | compact above 128 |
| Checkpoint | 4 KiB |
| Resume prompt | 4 KiB |
| Introspection stdin JSON | 16 KiB |
| Introspection stdout JSON | 16 KiB |
| Introspection attempts per turn | 3 |
| Resume attempts per thread | 8 |
| Base backoff | 1 second |
| Max backoff | 5 minutes |
| Durable hosted record | existing 1 MiB hard cap |

Backoff is exponential with deterministic jitter derived from the thread ID digest. Exhausting introspection attempts marks the thread `blocked` unless its deadline expired, in which case it fails. Exhausting resume attempts marks it `exhausted` and sends a terminal failure completion to the source.

## Legacy lifecycle compatibility

The protobuf shapes for `PromptTaskRequest` and `TaskLifecycleRequest` remain decodable, but every operation fails closed with a fixed retirement error directing callers to `ActorMessage Ask`. These legacy endpoints delivered `BridgeIntent` directly or kept completion authority in a disposable service map, so mapping them after admission would still bypass ActorTask credit, target-authoritative thread identity, settlement, and introspection.

There is no compatibility model-task authority. All new and existing callers must use `ActorMessage Ask → ActorTask → durable thread → ActorTaskCompleted`. Bridge records retain runtime delivery/ACK/replay only.

## File-level implementation slices

1. **Contracts:** `services/subagents/api/subagents/v1/subagents.proto`, generated Go/TS, golden fixtures; add optional thread fields, settlement/introspection messages if they cross protobuf, and owner-private thread status frame.
2. **Durable structs:** `services/subagents/internal/application/durable.go`, `messages.go`; add v3 thread/scheduler structs, effect messages, and terminal result metadata.
3. **Store validation:** `services/subagents/internal/state/store.go`; validate v2/v3, topology-neutral identities, bounds, references, compaction, and quarantine cases.
4. **Config:** `services/subagents/internal/config/config.go`, config tests, managed `private_config.toml.tmpl`; add exact `[hosted_pi].introspection_model`.
5. **Agent scheduler:** `services/subagents/internal/actors/agent.go`; migrate on load, admit threads, schedule one active prompt, persist ACK worker result, gate completion through introspection, redrive restart work.
6. **Introspection effect:** `services/subagents/internal/hostedpi/`; add `IntrospectionRunner` that spawns Pi RPC mode with exact isolation flags and stdin/stdout JSON.
7. **Hosted bridge:** `home/dot_pi/private_agent/extensions/hosted-pi-bridge/`; report thread/turn/delivery/run-counter evidence and keep PromptTaskCoordinator idempotent by daemon-issued identity.
8. **Service routing:** `services/subagents/internal/service/service.go`; route legacy lifecycle APIs through durable thread state and expose owner-private projection only after commit.
9. **Docs/tests:** update `docs/subagents.md`, `ROADMAP.md`, and actor/service/hosted bridge tests.

## Test matrix

| Area | Required proof |
| --- | --- |
| Identity | Exact replay returns same `thread_id`; same `chain_id` with different task creates different thread; registry rejects duplicate logical actors across homes/bindings; no physical node/DNS in identity hash. |
| Migration | v2 crash before rename reloads v2 and remigrates; crash after rename reloads v3; no prompt admission before migration save commit. |
| Admission | `ActorTaskAccepted` is sent only after thread/scheduler durable commit. |
| Scheduling | Task B queues while A active; B cannot mutate A; after at most two new tasks an eligible resumable A runs; scheduler does not claim cross-actor worktree enforcement. |
| ACK/settlement | ACK commits cursor plus worker answer/settled evidence before response but does not complete; `agent_end` alone never completes; exact `agent_settled` evidence gates introspection. |
| Introspection runner | Pi RPC mode receives JSON over stdin, stdout strict JSON is parsed, exact model is used, provider auth is Pi-owned, and no tools/extensions/templates/actor bridge are available. |
| JSON parser | Duplicate keys, extra keys, fences/handles/runtime IDs/credential paths, markdown fences, trailing bytes, malformed UTF-8, and oversize fields fail closed. |
| Completion | `completed` requires high confidence; `Terminal.Result` equals full bounded worker answer, not introspection summary; source disconnect/reconnect renders once. |
| Resume/wait/block | `continue` stores checkpoint/next prompt and resumes with backoff; `waiting`/`blocked` do not auto-run without typed evidence. |
| Restart/compaction | Active, settled, introspecting, resumable, and pending-completion states recover without duplicate prompt or completion; compaction preserves non-terminal identity. |
| Privacy | Public roster/status/logs redact prompts, answers, checkpoints, model, runtime/session/fence/handle/thread internals, host/port/DNS, and tmux/process details. |
| E2E | Fresh hosted runtime proves A incomplete -> B completes -> A resumes and completes across daemon restart with no polling, pane inspection, or operator reminder. |

## Consequences

Hosted actors gain durable work memory independent of the Pi bridge's current delivery. The scheduler can fairly resume incomplete work without conflating it with later mailbox items. Introspection remains probabilistic evidence, but completion is deterministic because only validated high-confidence output for the exact active thread can unlock a durable terminal transition, and the deliverable remains the worker answer routed by `ActorTaskCompleted`.
