# ADR 0004: Supervisor hierarchy and owned workflow actors

## Status

Accepted.

## Decision

The subagents daemon is moving authority out of service-owned maps and into bounded GoAkt actors under the long-lived service guardian:

- `HostedRuntimeSupervisor` owns hosted runtime children by Death Watch; runtime subprocess effects remain in `HostedPiRuntimeActor` and report typed completions.
- Each bridge connection gets a watched `BridgeSessionActor`; committed owned deliveries notify the session actor with direct `Tell`, and it performs post-fence replay in order without normal polling.
- GoAkt `TopicActor` remains the only projection subscriber/fan-out authority.
- `TaskCoordinatorActor` and `WorkflowRegistryActor`/`WorkflowActor` keep PM-independent progress state. Workflows advance worker -> reviewer -> QA -> correction/completed from typed evidence messages rather than UI state.
- `PersistenceSupervisor` records fail-closed durable quarantine. Durable failures must deny new mutations until explicit recovery rather than silently continuing.
- `ClientSessionActor` is the per-client authority lifetime boundary; client teardown removes client credentials/views only.

All actors use bounded mailboxes. Receive handlers only mutate in-memory state or enqueue typed effects; blocking work runs outside Receive and returns typed messages. Owned bridge delivery remains at-least-once with dedupe, bounded retained results, direct `Tell` after durable commit, bridge heartbeat supervision, and post-fence replay ordering.

## Runtime-owned tmux panel projection

The pane and communication visual language is governed by the approved [Actor UX design system](ACTOR-UX-DESIGN-SYSTEM.md).

Status: **Proposed; not implemented**. This section is canonical for the approved runtime-owned panel projection design. It does not claim that runtime-driven tmux panel updates already exist.

Implemented behavior includes hosted Pi launch with `--tui-mode fullscreen`, so Pi owns transcript navigation and scrolling inside the exactly-owned pane. The runtime-owned panel projection below is proposed daemon/runtime behavior; tmux `history_limit` is only a proposed panel preference and cannot substitute for Pi fullscreen transcript scrolling. Source-only Linux end-to-end verification after rebuild confirmed hosted Pi fullscreen transcript scrolling: every hosted inner pane and the visible project-manager pane reported alternate-screen mode and a tmux mouse flag, default Pi fullscreen PageUp/PageDown bindings apply because no keybinding override exists, and a cross-actor Ask completed in the visible four-pane topology. This verification covers the hosted Pi fullscreen mechanism, not the proposed `[actors.panel].mouse_scroll` template preference.

### Authority flow

```text
AgentActor productive state or WorkflowActor productive state
→ emits typed PaneProjection
→ HostedPiRuntimeActor validates exact ownership
→ tmux visualization adapter updates only the owned pane
```

Invariants:

- The model never executes tmux commands.
- `AgentActor` or `WorkflowActor` is the only productive-state source for a `PaneProjection`.
- `HostedPiRuntimeActor` must validate exact ownership before any visualization effect: owned runtime identity, server/session/window/pane identity, process token, pane token, and current fence must match the durable ownership record.
- The tmux visualization adapter may update only the owned pane. It must not read, write, attach to, rename, kill, resize, send input to, or decorate foreign tmux resources.
- Exact ownership validation failure is fail-closed and yields a `visibility-degraded` outcome rather than best-effort updates.
- Process liveness, Pi liveness, tmux liveness, bridge heartbeat, socket connectivity, and pane existence are never productive progress. They are runtime/visibility health signals only.

### PaneProjection display contract

A `PaneProjection` is UI-only and bounded. It may carry only:

| Field | Meaning | Status |
| --- | --- | --- |
| `display_name` | Authoritative actor or workflow display name from daemon state | Proposed |
| `role` | Dynamic role label from daemon state | Proposed |
| `access_mode` | Writer/read-only access mode for the selected project/worktree | Proposed |
| `productive_phase` | One of the canonical productive phases below | Proposed |
| `active` | Active decoration flag for the currently active unit of work | Proposed |
| `history_count` / `history_limit` | Bounded scroll/history hint, never raw scrollback | Proposed |
| `visibility_health` | `ok`, `degraded`, or `visibility-degraded` | Proposed |

Productive phases: `idle`, `working`, `waiting`, `reviewing`, `testing`, `correcting`, `failed`, and `degraded`.

Display rules:

- Authoritative display name, dynamic role, and writer/read-only access mode are rendered from daemon state, not template strings supplied by the model.
- Active decoration is a centrally controlled style applied when `active = true`.
- Realtime status is shown only in borders. Pane body content remains the owned Pi/tmux process output and is not overwritten by status widgets.
- Scroll hint/history policy is explicit: hosted Pi fullscreen transcript scrolling is the implemented mechanism. The panel may show a bounded history hint derived from `history_count` and proposed `history_limit`, but tmux history cannot substitute for Pi transcript scrolling; the projection must not expose raw prompts, payloads, or terminal scrollback.
- Style tokens are centrally controlled. Workflow templates and actors cannot inject tmux format strings, terminal escape sequences, or arbitrary style fragments.
- No raw principals, session IDs, PIDs, handles, fences, credentials, prompts, or payloads may appear in the projection or in tmux format inputs.

### Update and failure policy

- Updates are event-driven and debounced. Productive-state changes, access-mode changes, display metadata changes, visibility-health changes, and active-decoration changes enqueue a bounded panel update rather than polling terminal state.
- The tmux visualization adapter uses bounded retries for transient tmux failures. Retry exhaustion does not imply actor failure; it records `visibility-degraded` and leaves productive progress unchanged.
- `failed` and `degraded` productive phases are chosen by actor/workflow state. `visibility-degraded` is a visualization outcome and must not be converted into productive progress.
- A disappeared or replaced tmux server/session/window/pane is foreign or indeterminate until exact ownership is revalidated; the adapter must not recreate or claim it as a side effect of projection.

## Consequences

The daemon can supervise owned bridge sessions, runtime effects, persistence, client sessions, tasks, and workflows independently of the PM UI. Runtime restart is required to instantiate the new hierarchy for existing daemon processes. Durable quarantine is intentionally fail-closed and may require operator recovery if persistence becomes indeterminate.
