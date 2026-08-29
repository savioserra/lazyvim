# Actor UX design system

Status: approved UX contract for implementation. This document is the exact visual and interaction design requested by the user.

## 1. Presentation layers

| Layer | Purpose | Allowed content |
|---|---|---|
| Realtime status | Temporary current state only | Authenticated connection plus daemon-published actor lifecycle; productive labels only after AgentActor/WorkflowActor exposes a typed productive phase |
| Conversation flow | Durable human-readable interaction | Received notes, requests, sent messages, replies, decisions, and failures |
| Expanded details | Optional operational context | Dynamic role, duration, delivery state, evidence summary |

Communication history must never be rendered in a fixed editor widget. Fixed UI is reserved for realtime status.

## 2. Semantic visual language

| Meaning | Icon | Theme color | Required wording |
|---|---:|---|---|
| Received note | `↓` | cyan/accent | `<Actor> sent a note` |
| Sent note | `↑` | blue | `Sent to <Actor>` |
| Outgoing request | `↗` | magenta | `Asked <Actor>` |
| Incoming request | `↓` | cyan/accent | `<Actor> asked you` |
| Reply | `↙` | green | `<Actor> replied` |
| Pending | `◌` | yellow/dim | `Waiting for <Actor>…` |
| Delivered | `✓` | green/dim | `delivered` |
| Replied | `✓` | green/dim | `replied in <duration>` |
| Failure | `!` | red | `Couldn’t reach <Actor>` or an equally specific natural failure |
| Realtime ready | `●` | green | `Ready` |

Use Pi theme tokens. Do not emit raw ANSI color sequences. Icons must never be the sole carrier of meaning; wording must remain understandable in monochrome terminals.

## 3. Authoritative identity

- Primary peer label: authoritative `display_name`.
- Secondary label: dynamic role in subdued text.
- Never use a role enum or hardcoded PM/worker/reviewer relationship.
- Never display raw principals, session IDs, PIDs, handles, fences, credentials, runtime IDs, or transport identities.
- Do not present roles in noisy all-caps when a natural display form is possible.

Example peer label:

```text
Code Reviewer · review
```

## 4. Exact conversation cards

### 4.1 Incoming note

```text
╭─ ↓ Project Manager · note
│ Please verify the lifecycle behavior.
╰─
```

Requirements:

- One conversation card.
- No duplicate popup notification.
- Does not trigger a model turn unless the typed protocol explicitly defines it as a request.

### 4.2 Incoming request

```text
╭─ ↓ Project Manager asked you
│ Review the lifecycle behavior and report blockers.
╰─
```

Requirements:

- This is the actual source-aware user message delivered to the hosted model.
- Do not add a second communication card containing the same prompt.
- The model receives authoritative source display metadata and the bounded request body.

### 4.3 Outgoing Tell

```text
╭─ ↑ Sent to Code Reviewer
│ The implementation is ready for review.
╰─ ✓ delivered
```

Requirements:

- Append only after authoritative admission/delivery state is known.
- A failure uses the failure card instead of a false success.

### 4.4 Outgoing Ask and reply

```text
╭─ ↗ Asked Code Reviewer
│ Does the recovery path preserve fencing?
│
├─ ↙ Code Reviewer replied
│ Yes. The stale fence is rejected before replay.
╰─ ✓ replied in 8s
```

Requirements:

- Render the completed question and reply as one coherent exchange card.
- While awaiting the reply, do not append repeated pending conversation entries.
- Use realtime status while pending:

```text
◌ Waiting for Code Reviewer…
```

- Clear the pending status when the exchange reaches a terminal state.

### 4.5 Failure

```text
╭─ ! Couldn’t reach Code Reviewer
│ Request expired before a reply was received.
╰─ retry available
```

Requirements:

- Use natural bounded failure text.
- Do not expose raw protocol errors by default.
- Never claim delivery, completion, or reply when the terminal result is uncertain.

### 4.6 User decision

```text
╭─ Project Manager needs a decision
│ The current production stage is complete.
│ Continue with implementation or revise the specification?
╰─ awaiting your response
```

Requirements:

- The WorkflowActor owns the durable pending decision.
- The card survives producer/client disconnection and is replay-deduplicated.

## 5. Compact tool presentation

Normal collapsed tool presentation:

```text
↗ Asking Code Reviewer…
✓ Code Reviewer replied
```

Expanded detail:

```text
Target       Code Reviewer
Intent       Ask
State        Replied
Duration     8s
```

Rules:

- Human rendering is compact and visually organized.
- Model-visible tool content must still retain every lifecycle ID, correlation value, state, and explicit next action needed to continue the workflow.
- Never replace machine-actionable model content with display-only prose.
- Raw JSON is not the default human view.

Actor list/status presentation:

```text
Actors
● UX Implementer       ready
● Architecture Review  ready
● UX QA                ready
```

The fixed Pi status bar uses the same authority but a compact one-line form, for example `actors UX Implementer:[redacted] ready Architecture Review:[redacted] degraded +2`. It is length-bounded, sanitized, and shows an overflow count instead of wrapping. Until a typed productive phase is added by AgentActor/WorkflowActor, the status bar intentionally prefixes lifecycle as `[redacted]` and never shows `working`, `testing`, or similar productive activity.

## 6. Layout and responsive behavior

- Use Pi TUI `Box`, `Container`, and `Text` with theme tokens.
- Default cards have a clear header, wrapped body, and optional subdued footer.
- Narrow panes may collapse borders but must retain direction, actor, intent, body preview, and terminal state.
- Bound previews and wrap natural text; do not overflow pane width.
- Expanded mode may reveal duration, dynamic role, evidence summary, and sanitized failure class.
- Resizing must not duplicate entries or lose semantic labels.

## 7. Replay and persistence

- Each communication has one stable dedupe key.
- Client-side interaction state is reduced by an explicit XState-style client reducer. It owns view-local connection, pending request, roster replay cursor, and render-snapshot state while daemon actors remain authoritative for durable lifecycle, authorization, routing, and productive progress.
- Reconnect/replay must not append duplicate visible cards.
- Incoming request prompt injection and its visual representation count as one conversation item, not two.
- Persist only bounded, sanitized conversation presentation data permitted by session policy.
- Daemon operational diagnostics must not persist prompts, answers, or raw payloads.

## 8. Pane status design

Pane borders are realtime projections, not communication history.

Example titles:

```text
● UX Implementer · implementation · working
○ Architecture Review · review · waiting
○ UX QA · quality assurance · testing
● UX Delivery Manager · coordination · waiting for decision
```

Truthful phases:

- idle
- working
- waiting
- reviewing
- testing
- correcting
- failed
- degraded

Rules:

- Productive phase comes from AgentActor or WorkflowActor state.
- Process, Pi, tmux, or heartbeat liveness is never productive progress.
- Runtime authority validates exact ownership before updating a pane.
- Ordinary client roster UI consumes authenticated daemon push (`ClientAgentRosterFrame`) with epoch/sequence fencing. It must not poll `ListAgentsRequest` for fixed status-bar refresh.
- No foreign tmux resources may be modified.

## 9. Scrolling

- Hosted Pi runs in documented fullscreen TUI mode.
- Pi owns transcript navigation via mouse/trackpad, PageUp/PageDown, Home/End, and transcript search.
- Outer tmux history is not a substitute for Pi transcript scrolling.
- Pane hints must say `transcript: wheel · PgUp/PgDn` only when fullscreen transcript mode is active.

## 10. Acceptance matrix

Implementation is not complete until live fresh-runtime E2E covers:

1. Incoming Tell card.
2. Outgoing Tell success card.
3. Incoming request as one source-aware user message.
4. Outgoing Ask plus reply combined card.
5. Pending status appears and clears.
6. Failure card.
7. Reconnect replay without duplicate cards.
8. Narrow pane and resize behavior.
9. Mouse and PageUp/PageDown transcript navigation without input-box capture.
10. Dynamic descriptive actor display names and roles.
11. Pane phase changes from productive actor/workflow state.
12. Compact human tools while model lifecycle sequencing continues correctly.

All tests and E2E must avoid tmux `send-keys`, stdin injection, terminal scraping, or mutation of foreign tmux resources.
