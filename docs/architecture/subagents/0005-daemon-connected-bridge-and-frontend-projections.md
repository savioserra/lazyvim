# ADR 0005: Daemon-connected hosted bridge and frontend projections

- **Status:** Accepted
- **Scope:** hosted bridge boundary, actor task/reply protocol, frontend projections, fixed status, migration, and test gates

## Decision summary

The target architecture separates durable actor authority from frontend projection state and treats every model-bearing Pi as an agent peer.

```text
User terminal Pi AgentActor
  owns: independent logical agent identity, mailbox, Pi process/model context attachment
  connects through: ephemeral authenticated ClientSessionActor transport
  sends: GoAkt Tell from its own ActorRef to another AgentActor
  receives: the target's correlated completion Tell at that same ActorRef

Hosted Pi AgentActor
  owns: stable logical agent identity, capabilities, lifecycle, productive state
  owns child infrastructure:
    HostedPiRuntimeActor -> exactly owned daemon-supervised Pi process/tmux lifecycle
    HostedPiBridgeActor  -> durable delivery, ACK, replay, readiness, Ask correlation for that Pi
  connects through: BridgeSessionActor for one ephemeral hosted bridge WebSocket connection

Projection frontends and dashboards
  own: local XState v5 render machines, cursors, cards, status widgets
  consume: authenticated projection facts from TopicActor/client-session replay
  never own: routing, lifecycle, delivery ACK, Ask completion, runtime, or productive progress
```

A user-launched terminal Pi is not contained by a hosted agent. It attaches to its own independently registered `AgentActor`, whose ActorRef is the source and reply destination for peer protocol messages. The terminal process supplies that agent's model context while connected; `ClientSessionActor` is only its authenticated WebSocket transport. Closing, reloading, or disconnecting removes the connection credentials, handles, subscriptions, and local views, but never turns a transport session into actor authority and never stops another hosted AgentActor or its owned Pi runtime. The source AgentActor retains correlated completion messages according to policy so a connection loss cannot erase an actor-protocol result.

A hosted Pi agent is a distinct long-lived hosted `AgentActor`. That AgentActor owns one daemon-supervised Pi process as execution infrastructure through `HostedPiRuntimeActor` and uses `HostedPiBridgeActor` as the durable authority for the owned Pi's authenticated bridge binding, delivery queue, ACK cursor/gap buffer, replay, readiness lease, mutation source scopes, and Ask correlations. The hosted bridge extension inside the owned Pi remains process-local client code; durable bridge state lives in the Go service under `services/subagents/`.

Terminal Pi agents and hosted Pi agents communicate as peers through authenticated actor messaging over the application and actor planes. Frontend XState projections remain local disposable views and are never agent or Pi authority. Diagrams, tables, public APIs, and UI text must not represent a terminal Pi as a frontend inside a hosted AgentActor.

The current implementation still stores some bridge delivery and mutation state in `AgentActor`. The implementation target is now fully specified: split that bridge aggregate into a durable supervised `HostedPiBridgeActor` named by `(agent_id, runtime_id, incarnation)` while preserving the accepted AgentActor lifetime and hosted Pi runtime invariants from ADR 0002, routing/persistence invariants from ADR 0003, and supervisor/workflow invariants from ADR 0004.

## Authoritative boundaries

| Component | Owns | Must not own |
| --- | --- | --- |
| Terminal Pi `AgentActor` | Independent logical agent identity and ActorRef, mailbox, capability/fence ledger, ordered outgoing tasks, correlated incoming completion messages, terminal-runtime attachment state | Another agent's runtime, WebSocket buffers, frontend cards/status, hosted placement authority |
| Hosted Pi `AgentActor` | Long-lived logical identity and ActorRef, mailbox, display name, dynamic role, lifecycle revision, capabilities, command ordering, owned runtime/bridge child references, productive phase | Terminal Pi lifecycle, WebSocket connection buffers, frontend roster/cards/status, tmux view state |
| `HostedPiRuntimeActor` | Exact hosted Pi/tmux process lifecycle for the owning hosted AgentActor, runtime incarnation, exact ownership validation, start/stop/adopt/retry, readiness lease effects, runtime degraded state | Prompt delivery queues, model answer correlation, terminal scraping, user-pane mutation, terminal Pi client lifecycle |
| `HostedPiBridgeActor` | Durable bridge binding for one hosted runtime incarnation: bridge principal, Pi session ID, current bridge handle/fence, delivery sequence, ACK cursor, ACK gap buffer, replay window, mutation source scopes, pending/completed Ask correlation, terminal completion tombstones, bridge lifecycle/readiness facts | Frontend rendering, roster layout, process ownership, public placement decisions, frontend completion authority, terminal Pi client state |
| `BridgeSessionActor` | One authenticated daemon push connection to a hosted bridge process; ordered push after durable commit; reconnect replay from ACK cursor; connection shutdown cleanup | Durable delivery authority, logical agent identity, model-visible completion state |
| `ClientSessionActor` | Ephemeral authenticated transport attaching a terminal Pi/frontend to its independent AgentActor; subscriptions, frame delivery, teardown | Source identity, peer completion authority, agent work, hosted runtime, workflow state |
| `WorkflowActor` | Optional independently supervised durable multi-agent workflow progress, assignments, pending decisions, productive phase, worker/reviewer/QA/correction evidence | Parentage or ownership of agents/Pi runtimes, PM UI state, tmux state, frontend card ordering |
| `PlacementAuthorityActor` | Local hosted creation authority and typed remote placement admission for its logical node | DNS identity, SSH/shell transport, automatic actor relocation |
| Frontend clients | XState v5 projection machines, deterministic reducers, status/footer/widget rendering, cards, local rendered-frame dedupe, reconnect UI state | Durable lifecycle truth, routing authority, ACK retirement, productive progress inference |

The daemon may expose sanitized projection snapshots and events to many frontends. Those projections are derived facts, not a second source of truth.

## Protocol planes and message classes

Two planes remain distinct:

1. **Workstation application plane:** the length-prefixed protobuf WebSocket API for terminal Pi actor-client sessions, hosted bridge connections, and future dashboards. It carries authenticated requests, replies, push frames, and snapshots. Unknown major versions fail closed; minor-compatible readers preserve protobuf unknown-field compatibility.
2. **GoAkt actor plane:** direct local/remote actors, Tell/Ask, supervision, DeathWatch, TopicActor PubSub, and optional trusted-network remoting between durable agent peers. Application protobuf messages do not expose GoAkt PIDs, actor paths, serializer names, or remoting internals.

Use regular GoAkt actor messages for authoritative mutations, peer routing, ordered delivery, task completion, and remote forwarding. An authenticated terminal command first reaches its own source `AgentActor`; that actor calls Tell on the target `AgentActor`, making its ActorRef the protocol sender. The target captures that sender/reply reference with the correlation record, processes through its owned runtime when hosted, and at completion calls Tell with `ActorTaskCompleted` to the original source ActorRef. `ClientSessionActor` only transports commands to and received actor messages from the terminal's AgentActor. It is never the source identity or completion owner. A hosted Pi agent likewise originates messages from its `AgentActor`; its bridge binding authenticates runtime evidence but does not replace the ActorRef. Incoming work for a hosted Pi is committed by its `HostedPiBridgeActor` before runtime delivery. Use GoAkt lifecycle mechanisms for actor start/stop, supervision, DeathWatch, and restart/adoption effects. Use GoAkt TopicActor topics only for bounded projection fanout and hints after the authoritative state mutation has committed. A TopicActor publication can never route, acknowledge, or complete an Ask and can never be the only carrier of terminal completion.

Remote node behavior:

- Hosted placement is explicitly typed by logical `target_node`; empty means local creation.
- Remote creation routes to that node's placement authority over the actor plane with bounded operation ID, deadline, dedupe identity, peer certificate proof, and replay/collision checks.
- DNS supplies addresses only. Logical node identity and mTLS identity come from configuration.
- Public list/resolve/Tell/Ask route by stable logical agent ID and durable home node after authorization. Private actors and host/port details are excluded from public surfaces.
- Automatic actor relocation remains disabled; stale home nodes fail deterministically.

## Hosted bridge supervision and lifecycle

Stable logical names are constants owned by the subagents service package. Public APIs never expose these names. The actor tree is:

```text
ServiceGuardian
├── AgentRegistryActor                  name: registry/agents
├── PlacementAuthorityActor             name: placement/<logical_node>
├── PersistenceSupervisor               name: persistence
├── ClientSessionActor[]                name: clients/<session_generation>
├── BridgeSessionActor[]                name: bridge-sessions/<session_generation>
├── WorkflowActor[]                     name: workflows/<workflow_id>
└── AgentActor[]                        name: agents/<agent_id>
    ├── [terminal binding: no owned hosted runtime children]
    └── [hosted binding]
        ├── HostedPiRuntimeActor        name: agents/<agent_id>/runtime/<runtime_id>
        └── HostedPiBridgeActor         name: agents/<agent_id>/bridge/<runtime_id>/<incarnation>
```

`AgentActor` is the logical peer, mailbox, source ActorRef, and capability boundary. A terminal-bound AgentActor has no daemon-owned runtime child; its user-launched Pi attaches through an ephemeral `ClientSessionActor`. A hosted AgentActor supervises and DeathWatches its owned runtime and bridge children. `HostedPiRuntimeActor` owns exact process/tmux identity only for that hosted agent. `HostedPiBridgeActor` owns runtime delivery/ACK state for one incarnation but sends the resulting `ActorTaskCompleted` back to the original source ActorRef. `ClientSessionActor` and `BridgeSessionActor` are transports only. `WorkflowActor` is independently supervised and coordinates agents by Tell; it is never their parent.

Lifecycle rules:

- A terminal Pi starts and stops under the user's terminal lifecycle and attaches to its independently registered AgentActor. Reload/disconnect/close revokes only the transport session, credentials, handles, subscriptions, and views. Its AgentActor mailbox and correlated received messages follow explicit retention/passivation policy; transport cleanup cannot discard an admitted task completion or stop any hosted agent/runtime.
- START creates or adopts `AgentActor`, then starts/adopts `HostedPiRuntimeActor`, then starts/adopts `HostedPiBridgeActor` from durable records before declaring bridge readiness.
- Same-name START while a non-terminal owned record exists is rejected unless exact STOP has durably retired the previous runtime PID and bridge binding.
- Explicit STOP is destructive only for exactly owned resources. It first sends `StopHostedBridge{agent_id,runtime_id,incarnation,reason=explicit_stop}` to the bridge, persists readiness false and terminal failures for pending deliveries, then sends `StopHostedPiRuntime` to the runtime, then retires live PIDs and credentials. Late bridge lifecycle or ACK messages for the stopped incarnation fail closed.
- Unexpected runtime exit advances incarnation only after exact ownership proof and cleanup. The old bridge receives `RuntimeIncarnationRetired` and rejects new admission; retained pending Ask correlations complete as bounded failure unless the ACK had already committed. The replacement runtime starts with a new bridge actor name and fence.
- Terminal Pi reload/disconnect destroys only local XState machines and the current application connection. Reconnect reattaches to the same authorized terminal AgentActor and drains its bounded correlated mailbox. It cannot adopt, replace, or clean up a hosted Pi runtime.
- Daemon restart enumerates durable agent/runtime/bridge records, validates owner-private paths and exact ownership tokens, adopts live runtime records, reconstructs bridge actors from bridge records, and resumes replay from the durable ACK cursor. Origin restart does not lose pending Ask correlations. Terminal client sessions are not durable agent authority and must reconnect/authenticate; global hosted AgentActors and exactly owned Pi processes remain available for adoption if exact ownership validates.
- Bridge actor crash is supervised restart-from-record. If the durable record is missing, mixed, or fails validation, the supervisor quarantines it, publishes degraded projection only after commit, and denies new mutations until explicit recovery.
- DeathWatch is a degradation signal, not authority to mutate foreign resources. Runtime death tells the bridge to stop admitting and to fail or replay based on durable state; bridge death makes runtime readiness degraded but does not kill Pi; AgentActor death during daemon shutdown never grants session cleanup permission to stop the global agent; terminal Pi client cleanup never grants permission to stop or mutate hosted runtime resources.

Remote-origin routing preserves the source AgentActor reference/logical address across the actor plane. The target sends `ActorTaskCompleted` by regular Tell to that original source actor; if its node is temporarily unavailable, the target retains the correlated terminal message for bounded re-drive. TopicActor is never on this protocol path.

## Identity, fencing, sequence, epoch, and incarnation rules

| Value | Scope | Rule |
| --- | --- | --- |
| `agent_id` | Public logical agent | Stable opaque identity; never a PID, tmux name, hostname, credential, or model role. |
| `runtime_id` | Hosted runtime generation | Stable for one hosted runtime generation; paired with `agent_id`. |
| `incarnation` | Hosted runtime restart/adoption | Monotonically increases for every replacement Pi/runtime after unexpected exit or explicit replacement; stale incarnation messages fail closed. |
| terminal Pi peer | User-launched source peer | Authenticated client session/generation/principal plus authorized display metadata; independent of hosted AgentActor lifecycle and never inferred from frontend state. |
| hosted Pi peer | Hosted AgentActor's owned model worker | Stable `agent_id` plus current hosted bridge binding, runtime ID, and incarnation; its Pi process is execution infrastructure owned by the hosted AgentActor. |
| `bridge principal` | Hosted bridge authenticated source | Derived server-side from the authenticated session/generation/principal/runtime tuple. |
| `handle`/`fence` | Capability attachment | Issued by daemon actor authority; every mutation requires the current fence; replacement revokes the old fence before admitting new mutations. |
| `source_mutation_sequence` | Authenticated source scope | Positive and exactly-one-increasing within `(session, generation, principal, target fence, runtime incarnation-or-client-peer-scope)`; same sequence with identical payload returns the retained durable admission/terminal state and re-registers only a disposable connection wake-up; collision fails closed. |
| delivery `sequence` | Hosted bridge delivery queue | Monotonic per bridge actor; ACK retires only the exact sequence/dedupe/kind after durable commit. |
| roster `epoch`/`sequence` | Client roster projection | Epoch is unique per daemon incarnation/projection source; a snapshot reset starts a new sequence, and lower epoch/sequence frames are ignored. |
| request/dedupe/chain IDs | Logical operation | Bounded, retained, collision-checked, and safe to reuse only in independent source scopes. |

A bridge reconnect pins the same Pi session ID and sends the last durable ACK cursor. Same-session reconnect preserves source scope. Explicit fenced replacement creates a new source scope only after old authorization is revoked. Pending queue entries retain their original source scope until ACK, deadline, or fail-closed recovery, even if another source mutates the same target.

## Durable delivery, ACK, replay, and task completion

Bridge delivery is at-least-once over the hosted runtime connection. The durable `HostedPiBridgeActor` owns runtime delivery retirement; the source and target AgentActors own the peer task/reply protocol. Service-local channels, in-memory waiters, TopicActor delivery, and result polling are never authoritative.

### Delivery admission

1. Caller admission authenticates session/admin credential, derives source `CommunicationPeer` server-side, checks capability, deadline, fence, hop limit, target, and source sequence before lookup or replay.
2. `AgentActor`/routing authority resolves the target logical peer and sends a regular actor message. Terminal Pi origin and hosted Pi origin follow the same actor-message route after authentication; only their connection/session authorities differ.
3. For a hosted target, the target's `HostedPiBridgeActor` handles `CommitBridgeDelivery{source_agent_ref,target_agent_ref,request_id,dedupe_id,chain_id,source_mutation_sequence,deadline,kind,payload}`. It appends a `BridgeDelivery` and `TaskCorrelation` to durable state, assigns the next delivery sequence, and persists before reporting admission.
4. After durable commit, watched `BridgeSessionActor` instances are told `PushCommittedBridgeDelivery{agent_id,runtime_id,incarnation,sequence}`. Push failure never retires the delivery.

### ACK cursor, out-of-order ACK, and replay

The durable ACK cursor is the highest contiguous delivery sequence whose terminal ACK has durably committed for the bridge actor. It is not the highest sequence ever seen and not a push cursor. The bridge record also stores a bounded ACK gap buffer keyed by sequence for validated higher ACKs that arrived before lower gaps.

ACK rules:

- `BridgeDeliveryAck{agent_id,runtime_id,incarnation,sequence,dedupe_id,kind,source_scope,delivered,reason,bounded_result}` is admitted only from the authenticated current bridge binding and current fence. Validation checks exact runtime ID, incarnation, Pi session ID, delivery sequence, dedupe ID, kind, source scope, payload bounds, and deadline.
- An ACK for `ack_cursor + 1` commits terminal state and advances the cursor through any contiguous already-buffered ACKs. Every advancement atomically retires those deliveries, updates source mutation results/tombstones, and emits dependent reply actor messages.
- A valid ACK for a retained sequence greater than `ack_cursor + 1` is durably stored in the gap buffer but does not advance the cursor, does not retire lower deliveries, and does not permit replay to skip the gap. The replay response after reconnect starts at `ack_cursor + 1`, includes every unacked gap delivery, and omits higher deliveries already terminal-buffered.
- ACKs for sequences greater than the highest emitted delivery, outside the retention window, with mismatched identity, stale fence/incarnation, or expired/malformed terminal data are rejected fail-closed without changing cursor or buffer.
- Duplicate ACK for an already committed sequence returns the retained terminal ACK result when the identity matches; mismatched duplicates are collisions and fail closed. Duplicate ACK for a buffered higher sequence returns the buffered pending result and still does not advance.
- Tests must prove that ACKing sequence 3 while sequence 2 is unacked cannot move `ack_cursor` past 1, cannot remove sequence 2 from replay, and cannot emit sequence 3's dependent terminal completion until sequence 2 commits.

Replay and retention are bounded. Evicted source mutation results leave tombstones and are never reexecuted. Tombstones retain enough identity to reject collision and replay outside the retention window without retaining prompts or answers.

### Authoritative actor task completion contract

Model work is a two-message GoAkt protocol, not a delayed WebSocket response or service-side notification:

```text
source AgentActor --Tell(ActorTask)--> target AgentActor
source AgentActor <--Tell(ActorTaskCompleted)-- target AgentActor
```

The authenticated application request commands the source AgentActor and receives only a bounded admission receipt. The source actor sends `ActorTask` with its ActorRef as sender. The target captures that original source ActorRef plus a stable logical source reference in durable correlation state. A hosted target commits runtime delivery through `HostedPiBridgeActor`; after the owned Pi completes and its ACK commits, the target AgentActor sends `ActorTaskCompleted` by Tell to the original source ActorRef. No service-local completion channel, `NoSender` dispatch, reply broker, TopicActor route, result polling, or client-session tuple is completion authority.

Durable key and schema:

- Canonical key: the versioned protobuf encoding of target logical reference, target runtime/incarnation/delivery sequence, source logical AgentReference, request ID, dedupe ID, chain ID, and source mutation sequence, hashed for storage.
- `TaskCorrelation v1` stores that key, the source logical AgentReference and captured ActorRef address, target reference, delivery identity, deadline, immutable payload digest, state, terminal digest/result, Tell-attempt state, replay expiry, and tombstone expiry. It never makes a WebSocket generation part of actor identity.
- Identical replay returns retained state. Any immutable-field or terminal-digest mismatch is a collision and fails closed.

State transitions:

```text
delivery_committed -> runtime_dispatched -> ack_buffered? -> ack_committed
      -> completion_tell_pending -> completion_told -> source_committed -> tombstoned
      \-> expired_failed ---------> completion_tell_pending
      \-> quarantined_failed -----> completion_tell_pending when safe
```

Exact actor messages:

- `SendActorTask` commands the authenticated source AgentActor to initiate work.
- `ActorTask` is sent by that source AgentActor to the target AgentActor with correlation and bounded task data; `ctx.Sender()` is the reply ActorRef.
- `CommitBridgeDelivery` and `BridgeDeliveryAck` durably drive a hosted target's owned runtime.
- `ActorTaskCompleted` is the normal correlated Tell from the target AgentActor to the original source ActorRef.
- `CommitReceivedTaskCompletion` durably records the message in the source AgentActor mailbox before any attached terminal transport is notified.
- `MarkTaskCompletionPresented` records presentation only after the terminal Pi persists the completion key with its model-visible custom message.

Recovery rules:

- A disconnected terminal Pi does not affect its source AgentActor's mailbox. `ActorTaskCompleted` is committed there and presented when an authorized terminal runtime reattaches.
- If a target or node restarts after terminal ACK but before the completion Tell, durable `completion_tell_pending` state re-drives the same `ActorTaskCompleted` to the source ActorRef/logical address. The source dedupes by correlation key.
- If the source actor is temporarily unreachable, the target retains and retries the completion Tell within the bounded replay policy. It never substitutes TopicActor publication or a WebSocket session lookup.
- Actor supervision/restart preserves the logical source address; remote routing resolves that address through the actor plane. A dead/passivated source that cannot be recovered causes a bounded terminal delivery failure, not delivery to a different client.
- The source AgentActor exposes received completion only to the authenticated Pi attachment authorized for that agent/model context. Public roster, status, and diagnostics remain redacted.
- The terminal renderer persists the completion key before or atomically with `pi.sendMessage(type=actor-client-task-completion)`. Replayed received messages do not create another model-visible completion.

The UI may describe a task as “Ask” because the caller expects a later result, but the actor protocol remains Tell `ActorTask` followed by Tell `ActorTaskCompleted`. Deadlines produce the same correlated failure message to the source AgentActor.

### Expected GoAkt implementation shape

The following is illustrative pseudocode. Exact repository messages remain immutable registered application types, and every persistence callback returns to the owning actor as a message.

```go
// The authenticated transport commands the terminal Pi's own AgentActor.
case *SendActorTask:
    target := resolveAuthorizedTarget(message.Target)
    correlation := newTaskCorrelation(ctx.Self(), target, message)
    persistOutgoing(correlation)
    ctx.Tell(target, &ActorTask{
        Correlation: correlation.Public(),
        Payload:     cloneBounded(message.Payload),
    })

// The target sees the real source ActorRef because an actor, not NoSender,
// issued the Tell. Persist it before dispatching work to the hosted Pi.
case *ActorTask:
    source := ctx.Sender()
    if source == nil || source == ctx.ActorSystem().NoSender() {
        rejectMissingActorSource()
        return
    }
    persistTargetCorrelation(message.Correlation, source.Path())
    ctx.Tell(hostedBridge, &CommitBridgeDelivery{Task: message})

// Runtime ACK is evidence for the target actor. It is not the reply route.
case *HostedTaskFinished:
    completed := retainedCompletion(message.Correlation, message.Result)
    persistCompletionTellPending(completed, originalSourcePath)
    ctx.Tell(originalSourcePID, completed)

// The source owns the received result before any WebSocket/frontend action.
case *ActorTaskCompleted:
    if commitReceivedOnce(message) {
        notifyAttachedTerminalProjection(message.CorrelationKey)
    }
```

The target must not call `ctx.Response`, because the model run is not a bounded GoAkt Ask. It must not require a second user tool invocation. One external command causes the source actor Tell, hosted work, and the target actor's automatic completion Tell.

```text
Terminal Pi     ClientSession     Source AgentActor     Target AgentActor     Hosted Pi
    | attach          |                  |                    |                   |
    | actor_tell ---->| SendActorTask -->|                    |                   |
    | admission <-----|<-----------------|-- Tell ActorTask ->|                   |
    |                 |                  |                    |-- durable work -->|
    |                 |                  |                    |<-- result + ACK --|
    |                 |                  |<- Tell Completed --|                   |
    |                 |                  |-- commit mailbox   |                   |
    |<-- render once -|<-- projection ---|                    |                   |
```

For a remote target, GoAkt remoting preserves the actor sender address. The target stores both the captured ActorRef address and stable logical `AgentReference`; recovery re-resolves the same logical source and re-drives the same completion key. TopicActor and WebSocket session lookup are never substitutes.

```text
source node                    target node
Source AgentActor --remote Tell ActorTask--> Target AgentActor
Source AgentActor <-remote Tell Completed---- Target AgentActor
```

Required tests:

- one transport command produces one `ActorTask` and one automatic `ActorTaskCompleted` without another command;
- target rejects peer work received from `NoSender`;
- terminal disconnect before completion leaves the source AgentActor mailbox authoritative;
- duplicate target completion Tell commits and renders once by correlation key;
- target restart after runtime ACK re-drives the pending completion Tell;
- source-node outage retains bounded target correlation and remote retry;
- TopicActor publication or client-session replacement cannot complete a task.

## Frontend-only XState v5 projections

Each frontend session owns disposable XState v5 machines and deterministic reducers. The ordinary `actor-client` extension owns the frontend state-machine package and must pin `xstate` exactly to `5.20.2` in `home/dot_pi/private_agent/extensions/actor-client/package.json` and its lockfile when implementing these machines; reducer tests live under the same extension-owned test path used by the actor client. These machines consume authenticated daemon facts and produce render snapshots only. This ADR does not add Node as a workstation bootstrap dependency because the dependency is extension-local and installed by the existing managed Pi extension lifecycle.

Required machines/projections:

| Projection | Input | Output |
| --- | --- | --- |
| Connection | WebSocket open/error/close, auth result, bounded reconnect attempts | `disconnected`, `connecting`, `connected`, `reconnecting`, `degraded`; retry text and disabled mutation state |
| Roster | `ClientAgentRosterFrame` snapshot reset/upsert/remove/status | Sorted actor list, overflow count, stable status-bar string, current epoch/sequence cursor |
| Pending requests | Ask admission receipts, deadlines, reply frames, client restart restore markers | Pending count/status text; hidden restore entries only, no visible pending cards |
| Conversation cards | Incoming notes/requests, outgoing Tell receipts, Ask terminal completions, failures, user decisions | Deduped cards matching `ACTOR-UX-DESIGN-SYSTEM.md` |
| Status bar/footer/widgets | Roster and pending request projection | Fixed compact status from daemon-published lifecycle only |
| Reconnect cursors | Last roster epoch/sequence, last reply completion keys, last bridge ACK when hosted | Replay requests and dedupe decisions |
| Responsive TUI | Current render width and theme tokens | Wrapped, bounded cards/status; no duplicate entries on resize |

Reducers must be pure and deterministic for a given event stream. They may store bounded sanitized presentation data allowed by session policy. They must not infer progress from tmux, process liveness, heartbeats, terminal output, or elapsed time.

## Authenticated fixed status without polling or scraping

The fixed status bar uses authenticated topic-backed events, not `actor_list`/`ListAgentsRequest` polling. Initial render obtains an authorized roster subscription and snapshot reset. Updates arrive as `ClientAgentRosterFrame` events from `ClientAgentRosterTopic` or its successor topic. The client applies epoch/sequence fencing and does not periodically poll list/status for refresh.

Status labels are lifecycle/visibility facts only unless `AgentActor` or `WorkflowActor` publishes a typed productive phase. Process, Pi, tmux, heartbeat, socket, or terminal liveness can affect readiness/degraded/visibility status; they never become `working`, `testing`, `reviewing`, or similar productive phases.

No frontend may scrape terminal contents, tmux panes, process tables, heartbeats, or renderer internals to infer actor state.

## Protobuf and state contracts

The canonical protobuf remains `services/subagents/api/subagents/v1/subagents.proto`. Implementation should evolve it additively while preserving the existing envelope rules.

Required public/application fields or messages:

- `Envelope`: protocol major/minor, session ID, generation ID, request ID, deadline, sequence, caller identity, agent handle, session credential, agent fence, one payload.
- `ActorMessageRequest`: mode `TELL`/`ASK`, target, bounded payload, dedupe ID, hop limit, chain ID, source mutation sequence.
- `ActorMessageResponse`: immediate admission/completion receipt. Hosted model Ask uses admission-only response and later reply frame.
- `BridgeDelivery`: sequence, source/target agent IDs, request ID, deadline, dedupe ID, hop limit, bounded payload, policy, kind, chain ID, source/target `CommunicationPeer`.
- `BridgeDeliveryAckRequest`: agent ID, runtime ID, incarnation, Pi session ID, delivery sequence, dedupe ID, kind, source scope, delivered flag, reason, bounded result.
- `BridgePushFrame`: ordered events/deliveries and latest emitted sequence.
- `ActorTaskCompletedFrame`: transport projection of a source AgentActor's committed `ActorTaskCompleted`; completion key, original IDs, terminal result/failure, source/target references, approved opaque provenance, and next action. The existing `ActorMessageReplyFrame` is a migration adapter only.
- `ClientAgentRosterRequest`: last epoch and after-sequence.
- `ClientAgentRosterFrame`: operation, epoch, sequence, agent reference or removed agent ID, sanitized status.
- Hosted admin/placement messages: operation, agent ID, project directory, trust choice, display name, role, optional logical target node.
- Workflow/task messages: lifecycle ID, target, bounded prompt/answer, dedupe/chain/hop/source sequence, terminal state.

Required durable state, whether stored in the current `DurableHostedRecord` or split into bridge-specific records during migration:

| State | Required contents |
| --- | --- |
| Agent durable state | revision, command sequence, authority binding, capabilities, attachments, revoked generations, current fence, runtime binding, lifecycle/productive metadata |
| Bridge durable state | bridge session/generation/principal/handle/Pi session/fence, bridge delivery sequence, delivery queue, delivery source map, source mutation scopes, highest-contiguous ACK cursor, ACK gap buffer, readiness lease generation, pending/terminal Ask correlations, terminal completion replay keys and tombstones |
| Runtime durable state | runtime ID, incarnation, launch spec, exact tmux/process tokens, session credential reference, ownership indeterminate/cleanup pending flags |
| Client/session replay | bounded response replay, roster cursor, reply completion replay/tombstones, subscription acknowledgements |
| Workflow durable state | lifecycle ID, actors, current phase, pending decision, evidence summary, terminal result/failure |

Records are schema-versioned, owner-private, bounded, atomically replaced, directory-synced, and quarantined fail-closed when persistence is indeterminate.

## Security, redaction, public surface, and resource limits

Public, roster, status, metrics, logs, and diagnostic surfaces must not expose credentials, credential paths, raw session IDs, generation IDs, principals, handles, fences, runtime IDs, process IDs, TTYs, hostnames, ports, certificate material, prompts, answers, raw payloads, terminal scrollback, tmux internals, or deployment identities. The full bounded answer and approved opaque correlation/provenance fields are allowed only inside the authenticated requesting model context or an explicitly authorized successor context bound by policy to the original requester. Model-visible tool results may include lifecycle/correlation IDs needed to continue work, but those IDs must be opaque, bounded, and nonsecret. Roster/status/diagnostics/public list and resolve surfaces show sanitized lifecycle, display name, dynamic role, and failure class only; they redact answers, prompts, and correlation details not needed by that surface.

Required limits:

| Limit | Target |
| --- | --- |
| Protobuf frame | 64 KiB maximum |
| Bounded text/payload | 16 KiB per model payload unless a narrower field applies |
| Outstanding bridge deliveries | 256 globally or a stricter configured cap |
| Source mutation result cache | 1024 retained results per source scope with tombstones for evicted sequences |
| Durable hosted records | 4096 records, 1 MiB each |
| Conversation presentation data | Bounded per session; default target 512 entries |
| Ask completion deadline | Bounded, default 30 minutes |
| Reconnect/backoff | Bounded per invocation; never an unhandled promise rejection or terminal process crash |

Failure modes:

- Unauthorized, stale fence, stale incarnation, sequence collision, replay outside window, malformed frame, or expired deadline fails closed before side effects.
- Durable persistence failure denies new mutations and publishes degraded/quarantined status.
- Uncertain external runtime identity remains degraded and untouched.
- Push failure leaves delivery replayable.
- Unknown remote home node or stale node fails deterministically without leaking transport details.
- Visualization failure records `visibility-degraded` without changing productive state.

## Migration and cutover

The implementation migrates by additive contracts and a single one-way durable schema path. There is no dual-writer authority migration. Existing upstream `pi-subagents` authority remains observed-upstream until explicitly retired.

Durable schema versions and markers:

| Record | Legacy marker | New marker | Owner | Precedence |
| --- | --- | --- | --- | --- |
| Hosted agent/runtime | `schema_version <= 2` with bridge fields embedded in agent/hosted record | `schema_version = 3`, `record_kind = agent-runtime` | `AgentActor`/`HostedPiRuntimeActor` | New record wins after successful migration marker fsync |
| Bridge | none or embedded legacy bridge fields | `schema_version = 1`, `record_kind = hosted-pi-bridge`, `migration_from_agent_revision` | `HostedPiBridgeActor` | Authoritative after matching agent-runtime marker references it |
| Ask correlation | legacy pending waiter/result fields | `schema_version = 1`, `record_kind = ask-correlation` | `HostedPiBridgeActor` | New correlation/tombstone wins; legacy waiter cannot complete |
| Source task mailbox | legacy service response replay only | `schema_version = 1`, `record_kind = received-task-completion` | source `AgentActor` | Actor mailbox record wins; transport replay is disposable |

Migration algorithm:

1. Stop new hosted bridge admission during startup migration and persist a `migration_in_progress` marker containing source record digest, target record names, and monotonic migration ID.
2. Read legacy hosted records without mutating them, validate owner-private paths and exact runtime identity, and compute deterministic bridge/correlation/replay records.
3. Write new records atomically, fsync each file and directory, then atomically write `migration_committed` referencing the new record digests.
4. On restart, `migration_committed` plus matching new records makes new records authoritative and legacy bridge fields read-only fallback for rollback. Missing committed marker with partial new records is mixed-state quarantine.
5. Idempotence: rerunning with the same source digest and target digests is a no-op; changed source digest, duplicate new key with different digest, or both legacy/new records claiming authority without a committed marker is quarantine.
6. Rollback boundary: rollback is allowed only before `migration_committed`; remove partial new records whose digests match the in-progress marker and resume legacy observed behavior. After `migration_committed`, rollback can only run code that reads new records; it must not write legacy bridge authority.
7. Old embedded bridge fields can be removed from durable records only after one released compatibility window with startup tests proving all committed v3/v1 records load and all uncommitted/mixed legacy states quarantine fail-closed.

Cutover phases:

1. Centralize names under workstation-owned constants: actor names, topic names, placement authority names, extension names, service names, state directories, status labels, record kinds, and schema versions. Remove hardcoded legacy prefixes only after adapters are in place.
2. Add durable `HostedPiBridgeActor` under `internal/actors/` with the stable name `agents/<agent_id>/bridge/<runtime_id>/<incarnation>` and route new hosted bridge connect/lifecycle/delivery/ACK messages to it. Keep current `AgentActor` fields readable only for migration/adoption/rollback before commit.
3. Move delivery queues, source mutation scopes, ACK cursor/gap buffer/replay, bridge readiness, and Ask correlations from `AgentActor` durable state into bridge durable state. Fail closed on ambiguous mixed state.
4. Route every model task as source AgentActor Tell `ActorTask`, then target AgentActor Tell `ActorTaskCompleted` back to the original ActorRef. Remove `NoSender` dispatch, service reply-broker authority, in-memory completion channels, and result polling.
5. Switch fixed frontend status to topic-backed roster subscriptions with epoch/sequence reset. Keep list/resolve commands for explicit user/tool requests, not refresh loops.
6. Replace ad hoc client state with frontend-local XState v5 machines and deterministic reducers behind the existing actor-client/hosted bridge API.
7. Drive WorkflowActor-owned worker/reviewer/QA/correction flows through typed evidence messages and task lifecycle events.
8. Run local and remote E2E gates; only then cut authority from legacy upstream execution for owned actors.
9. Retire compatibility shims and legacy names only after cutover evidence and rollback window completion. Remove `pi-subagents`, `pi-tmux-subagents`, and `tmux-subagents` packages/tests/docs only after owned execution parity and observer replacement are accepted.

## Repository ownership and file impact

| Concern | Owner/path |
| --- | --- |
| Canonical schema | `services/subagents/api/subagents/v1/subagents.proto`; generated Go/TypeScript regenerated together |
| Durable daemon actors | `services/subagents/internal/actors/` and `services/subagents/internal/application/` |
| WebSocket application plane and session actors | `services/subagents/internal/service/` |
| Remoting and placement | `services/subagents/internal/remoting/`, `services/subagents/internal/service/placement_*` |
| State store and secure paths | `services/subagents/internal/state/`, `services/subagents/internal/securepath/` |
| Hosted bridge extension | `home/dot_pi/private_agent/extensions/hosted-pi-bridge/` |
| Ordinary actor client extension | `home/dot_pi/private_agent/extensions/actor-client/` |
| Lifecycle package and naming/config | `home/dot_local/share/workstation/packages/subagents/`, managed private config template |
| Architecture docs | `docs/subagents.md`, `docs/architecture/subagents/` |
| Legacy observer/tests | `home/dot_pi/private_agent/extensions/tmux-subagents/`, `tests/tmux-subagents/` retained until cutover |

No repository-level wrapper, root Go module, root CLI, Makefile, OS package-manager dependency, or Node bootstrap dependency is introduced.

## Implementation phases and acceptance gates

| Phase | Acceptance gates |
| --- | --- |
| 1. Contracts | Additive protobuf/state contracts for bridge actor, Ask correlation, reply frame replay, roster events; codegen verify; golden fixture updates intentional |
| 2. Bridge actor split | `HostedPiBridgeActor` owns durable queue/scope/ACK/readiness; AgentActor remains logical; restart adopts existing records; persistence quarantine tests pass |
| 3. Actor task completion | Recovery test proves target runtime ACK causes exactly one correlated `ActorTaskCompleted` Tell to the original source ActorRef; source mailbox survives terminal disconnect and dedupes replay; no result polling exists |
| 4. Frontend projections | XState v5 machines/reducers cover connection, roster, pending Ask, conversation cards, status, reconnect cursors, and responsive rendering; snapshot/replay/dedupe tests pass |
| 5. Topic-backed status | Fixed status bar uses authenticated roster topic frames; no periodic `ListAgentsRequest`/`actor_list` refresh; no tmux/process/heartbeat inference |
| 6. Workflow ownership | WorkflowActor drives PM-independent worker -> reviewer -> QA -> correction/completed from typed evidence and publishes productive phases |
| 7. Local E2E | Terminal Pi AgentActor Tells a hosted AgentActor, receives its correlated completion Tell, and renders one model-visible card; terminal disconnect preserves the source mailbox; daemon restart replays/adopts; exact STOP cleans only owned resources |
| 8. Remote/VPS E2E | Three logical service nodes (`node-a`, `node-b`, `node-c`) on an owner-controlled private overlay or disposable VPS/VM network, each with distinct actor/discovery/peers/application ports, URI-SAN mTLS, schema-v2 config, remoting enabled only for the test; evidence includes trusted-node placement from node-a to node-b, remote public roster reconciliation on node-c, local-to-remote Tell/Ask, durable reply routing across target and origin daemon restarts, ACK cursor gap replay, stale home-node deterministic failure, redacted public/status output with no host/port leak, logs and command transcript stored as sanitized test artifacts |
| 9. Exact STOP/recovery | Same-name restart after STOP, unexpected Pi exit retry with newer incarnation, indeterminate tmux/process identity fail-closed, no foreign pane/session mutation |
| 10. Cutover | Legacy authority disabled only after parity evidence, rollback plan, and docs/tests updated |

Fast validation before completing implementation changes remains the repository-required check set, plus the focused subagents service commands under `services/subagents`.

## Decisions

- `hosted-pi-bridge` is a daemon-connected hosted bridge boundary with durable Go actor state, not frontend projection state.
- `AgentActor` remains the logical identity/capability authority and global lifetime boundary.
- Bridge delivery, ACK, replay, source mutation scopes, readiness lease, and Ask correlations belong to `HostedPiBridgeActor`.
- Task completion is the target AgentActor's correlated Tell to the original source ActorRef after its bridge commits runtime evidence; the source AgentActor durably receives it and its terminal attachment renders it once. Result polling is not part of the public API.
- Frontend roster/cards/status/reconnect state is frontend-local XState v5 projection state.
- Fixed status is topic-backed and authenticated; polling and scraping are rejected.
- GoAkt topics are projection fanout only; regular actor messages and durable records are authoritative for mutations, remote forwarding, ACK retirement, and terminal Ask completion.
- Remote routing uses configured logical nodes and mTLS actor-plane trust; DNS and transport addresses are not identity.
- The frontend state-machine implementation is owned by the actor-client extension and pins `xstate` `5.20.2` when implementation lands.

## Rejected alternatives

| Alternative | Reason rejected |
| --- | --- |
| Keep all bridge state inside `AgentActor` | Couples logical identity to transport delivery, complicates recovery, and caused lost in-memory Ask waiter risk. |
| Put XState machines in the daemon/bridge as UI authority | Makes session-local rendering state durable authority and hard to share across frontends. |
| Use `ListAgentsRequest`/`actor_list` polling for fixed status | Wasteful, stale, and bypasses authenticated topic replay/fencing. |
| Infer status from tmux, process, heartbeat, terminal output, or renderer state | Violates truthfulness and security boundaries; liveness is not productive progress. |
| Use GoAkt TopicActor for ordered durable delivery | PubSub retention is not the durable ACK/replay queue. |
| Use in-memory channels for Ask terminal completion | Recovery can lose waiters even when durable ACK succeeds. |
| Add actor_result/result polling | Creates a second completion path and duplicate model-visible outcomes. |
| Expose GoAkt PIDs, host/port, tmux IDs, credentials, or process IDs in public APIs | Leaks implementation and security-sensitive details. |
| Use SSH/shell/tmux transport for remote placement | Bypasses typed actor-plane placement authority and exact ownership rules. |
