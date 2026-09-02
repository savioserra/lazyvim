---
id: TASK-19
title: Fix terminal actor delivery stalls and stale ACK fences
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 03:03'
updated_date: '2026-09-02 06:47'
labels: []
dependencies: []
references:
  - >-
    docs/architecture/subagents/0005-daemon-connected-bridge-and-frontend-projections.md
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - services/subagents/internal/service/actor_reply_broker.go
priority: high
type: bug
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Terminal actor delivery remains unreliable in two related live paths. First, consecutive ActorTaskCompleted results can commit durably but wait for a later user turn before presentation. Second, hosted agents use the source display label `Project Manager` for proactive Ask/Tell; the panel shows optimistic `Asking Project Manager…`, but durable outboxes retain a `project-manager` alias, terminal regular deliveries reject ACK with a stale attachment fence, and later messages remain pending credit. Diagnose canonical reply-to-source resolution, terminal attachment/fence renewal, regular delivery ACK identity, reply broker push, presentation wake, and persisted dedupe/cursor state. Durable completion or optimistic tool text is not successful human delivery.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Three or more consecutive fresh ActorTaskCompleted results automatically reach and wake the requesting terminal without another user turn, pane inspection, or durable-state polling
- [ ] #2 A hosted actor can Ask and Tell the authoritative source terminal using a canonical reply capability or resolved identity; display-name aliases never create an unroutable pseudo-agent
- [ ] #3 Terminal reconnect/reattach renews the regular-delivery ACK fence consistently, replays committed work exactly once, and cannot loop on fence rejection or credit churn
- [ ] #4 Optimistic Asking/Sending UI transitions to authoritative admitted, busy, failed, or completed state and never implies delivery before admission
- [ ] #5 Service and actor-client regressions reproduce consecutive-completion delay plus hosted-agent-to-source Ask under fence rotation, and live E2E proves both without polling or pane inspection
- [x] #6 No transport/client prefix maps to a hardcoded Project Manager, worker, reviewer, QA, or other semantic role; terminal display name and role are optional validated dynamic AgentActor metadata with neutral role-free fallback
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce canonical client identity alias leakage, stale regular ACK fence, and missed consecutive wake in focused service/client tests.
2. Preserve canonical client stable IDs while keeping friendly display metadata; resolve or reject presentation aliases before any durable outbox write and define server-issued reply-to-source routing.
3. Make regular delivery ACK obtain the current self attachment fence and retry exactly once after fenced reattach without reinjection or duplicate presentation.
4. Wake canonical terminal sessions for every committed completion and add bounded legacy alias repair/quarantine that preserves dedupe and never fabricates success.
5. Run service/client/security/reconnect regressions and a live multi-message hosted-agent-to-source E2E before finalization.

6. Remove hardcoded PROJECT MANAGER and TERMINAL PI role/display assignments. Add an authenticated terminal metadata registration/update path so communicationPeer resolves canonical AgentActor metadata; presentation labels never become routing identity.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Additional live evidence: sequence 34 appeared only after the user sent a later turn, rather than waking/presenting when the durable completion first committed. Its payload was only a report receipt, but the delayed wake behavior confirms the consecutive-completion presentation stall remains observable.

Live proactive-Ask evidence: UI QA retained four outbox messages to the project-manager alias (one sent with high retry count, three pending credit); UI UX retained three. Daemon logs show terminal delivery ACK rejection under a rotated fence and repeated credit_reservation_missing redrive. The visible panel wording was optimistic local tool state, not authoritative delivery.

Architecture diagnosis sequence 39 identified three interacting bugs: communicationPeer rewrites canonical client:* stable identity to presentation alias project-manager; regular delivery retains stale ACK fence across reattach; broker wake depends on serialized source principal matching the active terminal. Frozen fix direction: preserve canonical stable IDs, resolve/reject aliases before durable outbox, add canonical reply-to-source capability, refresh/retry ACK once with unchanged delivery identity, wake canonical sessions, and quarantine ambiguous legacy alias items.

TASK-19 implementation is assigned to the retained UI Projection Implementer after completion of TASK-1.1 correction writing. It may change service and actor-client code but remains the sole writer in its worktree; independent review/QA remain read-only.

Operator deployment decision: after reviewed code is applied, perform an explicit whole-crew recovery teardown. Preserve the active PM until the handoff point; retire each exactly owned hosted actor/runtime, remove observer clients/window, stop the daemon, clear only the configured actor durable state after exact ownership is gone, restart the daemon, reload/reconnect PM, recreate the five logical UI crew actors with fresh Pi runtimes in their clean isolated worktrees, and rebuild the labeled 3x2  tmux window. This explicit operator request authorizes stop/shutdown only for this deployment reset; ordinary phase transitions still retain actors.

Correction to the preceding deployment note: the rebuilt labeled 3x2 tmux window is named `crew`.

Operator correction: Project Manager is a dynamic role, not a terminal actor class or transport alias. The diagnosis recommendation to retain hardcoded PROJECT MANAGER display/role is rejected. communicationPeer and ensureTerminalAgent must not synthesize semantic roles from client:*; terminal identity metadata must be dynamically registered and persisted, and absent metadata must use a neutral role-free fallback.

Correction applied: rejected hardcoded PROJECT MANAGER/TERMINAL PI presentation semantics. Terminal client session now accepts optional validated display_name/role metadata, registers/updates the terminal AgentActor without rotating client:* identity, persists metadata in the durable record, and communicationPeer resolves current AgentActor metadata with neutral fallback and empty role. Hosted reply-to-source routing now uses only explicit source/reply-source aliases; display names such as Project Manager never route. Added terminal metadata/dynamic role and display-routing regressions.

Correction validation: capabilities passed; actor-client passed 41/41; hosted-pi-bridge passed 37/37; service gate passed npm ci, codegen verify, go test -race ./..., go vet ./..., npm test; git diff --check passed. Host blockers unchanged: stylua missing, scratch chezmoi blocked by missing tmux, tmux-subagents 93/97 with spawn tmux ENOENT.

Writer sequences 43/44 completed and were integrated: canonical client identity and reply alias/fence handling landed first, then all hardcoded PROJECT MANAGER and TERMINAL PI metadata was removed. ClientSessionRequest now carries optional authenticated display_name/role; registry updates metadata durably without identity/fence rotation; communicationPeer resolves current AgentActor metadata with neutral role-free fallback; display names cannot route. Writer gates passed actor-client 41/41, hosted bridge 37/37, service codegen/race/vet/protocol, capabilities, and diff.

PM post-integration gates on 7d1ac9e passed: actor-client 41/41, hosted bridge 37/37, capabilities, service codegen/go race/vet/protocol 6/6, git diff check, and scratch chezmoi dry-run. Independent architecture/security review sequence 45 and QA sequence 46 are active before the operator-requested fresh deployment reset.

Independent review sequence 45 found no architecture/security implementation blockers, but two release-gate test gaps: no regression sends three or more consecutive completions and proves immediate reply frames without another request; stale-fence ACK retry is helper-mocked rather than integrated against real daemon fence rejection, reattach, and exactly-once retirement with unchanged delivery identity. QA sequence 46 conditionally passed code but hosted tmux was unavailable; PM scratch evidence supersedes the environment block. TASK-19 remains open until both regressions and live reset E2E pass.

Operator-requested deployment reset executed on main a85c40d/7b7e517 code: chezmoi apply succeeded; five exact hosted actors were stopped; the old crew observer window was removed; daemon stopped; only configured actor state was cleared/recreated mode 0700; five verified leftover hosted Pi PIDs were terminated by exact WS_SUBAGENTS_AGENT_ID match; daemon restarted active; all five logical actors were recreated fresh and report available; labeled 3x2 crew window rebuilt with PM plus five actors. Active PM must /reload to load the new actor-client before live notification E2E.

Fresh post-reset live proof passed: sequences 47, 48, and 49 were admitted consecutively without intervening user input and automatically produced NOTIFY_E2E_1/2/3 in order and exactly once, with no pane inspection or durable-state polling. Fresh cards used neutral  presentation with empty role rather than any hardcoded semantic role, while each target retained its independently registered dynamic metadata.

Correction: the neutral source presentation label observed in sequences 47-49 was `client`; no semantic role was synthesized.

The remaining TASK-19 release gates will be closed together with the production intent correction: add three-consecutive service wake regression, real daemon stale-fence reattach/ACK regression, and hosted reply-to-source Tell plus Ask live coverage.

Writer sequence 50 integrated release-gate regressions: three consecutive completion reply frames without another request, real-wire stale-fence ACK rotation, and canonical reply-to-source Tell/Ask with display metadata rejected for routing. Task remains open for independent review and live Tell/Ask/fence evidence.

Deployment/reset evidence: five hosted sessions were exactly stopped and recreated after daemon rebuild; all five authenticated bridges report available and BridgeReady. Fresh records exposed separate lifecycle projection defect BridgeReady=true with state=starting, tracked as TASK-21. Live consecutive Tell/Ask matrix must resume after current terminal `/reload`; this deployment does not waive that acceptance gate.

Operator confirmed `/reload` did not fully activate the deployed actor-client behavior. Remaining delivery E2E must run from a newly started terminal Pi process, not a reloaded process; hosted bridge changes still require hosted runtime reincarnation.

Live post-deployment Tell sequence 69 automatically pushed a terminal frame, but frontend misclassified it as an Ask reply (`Actor Ask replied`, answer `delivery acknowledged`). Automatic push works in this case; intent-specific presentation is wrong. Tell ACK must reconcile a TUI-only delivered/failure state exactly once without model follow-up.

Sequence 70 provided a second automatic Tell completion push misrendered as Ask reply/delivery acknowledged; push delivery is consecutive, presentation intent remains wrong.

New live failure after compaction/thread work: reviewer completed TASK-22.1 Ask 92 in its hosted runtime, but the requesting terminal received no completion notification. Operator observed all agents finished while PM remained waiting. Recovery required a second Ask 93 requesting the already-completed review, violating automatic exactly-once completion presentation and causing duplicate task pressure. This is independent of the Tell-as-Ask UI misclassification and confirms TASK-19 remains a runtime blocker.

PM state inspection after operator report localized the missing-notification failure: Ask 92 and recovery Ask 93 were both already durably present in the terminal AgentActor SourceTaskHistory and ReceivedTaskCompletions with Completed=true; source outbox and completion-Tell pending were empty. Neither result reached the actor-client presentation path. The stall is therefore after source durable commit/completion receipt, in reply broker/topic push/client delivery or presentation, not unfinished agent work. PM recovered review 92 from authorized owner-private durable state without pane inspection.

ASAP correction implemented on main: actorReplyBroker now uses a bounded blocking mailbox so authoritative completion wake projections cannot be silently dropped at capacity, and a 250ms server-side reconciliation tick drains each connected terminal source AgentActor durable ReceivedTaskCompletions as loss recovery. Event push remains primary; there is no actor_list/client/UI/pane polling. Regression unsubscribes the broker from ActorMessageReplyTopic and proves a completed Ask still pushes automatically without another client request. Focused service race count=20, full Go race/vet/codegen/protocol, capabilities, 87 non-real-tmux observer tests, diff, and scratch apply passed.

Deployed commit 9b4fc95 after full source chezmoi apply/sync. User explicitly requested full session restart: exactly stopped all six hosted crew actors, applied source, rebuilt daemon, restarted systemd-user service, recreated all six retained logical actors/runtimes from their worktrees, and rebuilt the seven-pane crew view while preserving the PM pane. Deployed binary contains actorReplyBroker.scheduleReconcile and service is active. Fresh live automatic completion proof is still required before finalization.

First post-deploy live evidence: pre-restart durable Ask 94 automatically arrived after daemon and all hosted runtime reincarnations, without a reminder, manual request, or pane inspection. This proves the new broker reconciliation recovers a completion whose topic wake/presentation was previously stalled across restart. It was presented once. Fresh post-deploy probes 95-97 remain pending for consecutive acceptance.
<!-- SECTION:NOTES:END -->
