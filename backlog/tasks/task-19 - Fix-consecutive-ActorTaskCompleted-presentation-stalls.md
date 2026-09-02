---
id: TASK-19
title: Fix terminal actor delivery stalls and stale ACK fences
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 03:03'
updated_date: '2026-09-02 22:20'
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

7. Reproduce hosted AgentActor A→B Tell/Ask through actor-client hosted bridge tools/ActorMessageRequest, trace admission, credit reservation, ActorTask delivery, target thread creation, completion return, and UI delivery on origin/main a57222a+.

8. Fix the regression with durable-before-effects semantics for hosted source identity/session rotation/stable ActorRefs/credit redrive without re-enabling raw or RemoteBridgeIntent Ask/Prompt.

9. Add race-safe Go and actor-client/extension regressions for hosted A→B Tell and Ask across fresh runtime rotation and exactly-once completion; run codegen, race, vet, npm, and focused gates.

10. Make hosted-pi-bridge lifecycle READY retry only exact transient durable-persistence-busy responses with bounded backoff and identical lifecycle payload/identity; keep auth/incarnation/non-busy rejection fatal.

11. Add extension and Go regressions for READY racing durable persistence, reconnect eventual Ready convergence, retry exhaustion, non-busy fail-closed, and no same-incarnation ready-to-starting regression; run relevant gates.

12. Prevent Pi follow-up turn lifetime from blocking the durable regular-delivery queue: treat the documented sendMessage call as synchronous enqueue, ACK Tell immediately after enqueue, and let Ask ACK only from correlated agent settlement; add a regression with an unresolved follow-up thenable proving later Tell admission/ACK is not head-of-line blocked.

13. Fix hosted ActorTaskCompleted delivery back into the source hosted actor as a durable same-thread continuation, enforce terminal-result barriers before nested orchestration advances, make stale duplicate credit grants idempotent, and harden prompt settlement identity for queued deliveries. Validate first with one client → worker → client Ask, then one client → reviewer → client Ask; do not restart multi-agent orchestration until both converge without warnings.

14. Replace live-probe-driven repair with a deterministic stale regular-prompt reincarnation harness: injected/unacked marker, rotated self fence, real service/WebSocket replay, abandoned-prior-executor terminal failure, durable-before-ACK settlement, exact transient busy retry, contiguous cursor retirement, later Tell/Ask liveness, and second restart exactly-once proof. Add bounded typed ACK mismatch diagnostics and do not run another live probe until this test passes repeatedly under race plus independent review.

15. Operator-requested production validation: sync reviewed source to the configured VPS using documented chezmoi lifecycle, verify local/remote daemon versions and mTLS/remoting readiness, then run strict terminal barriers for 2–3 rounds of client→local1→local2→client, client→local1→remote2→local-client, and a final critique/report/mediation debate. Abort on any warning, rejected ACK/credit, nonterminal admission, or missing exact completion.
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

Fresh post-deploy consecutive acceptance passed: Ask 95, 96, and 97 were admitted together and automatically presented exact NOTIFY_RECONCILE_1/2/3 results without another operator reminder, pane inspection, or durable-state read. Delivery order reflected completion order (97, 96, 95), each exactly once. Combined with pre-restart recovery 94 and focused lost-topic regression, reply reconciliation is live. TASK-19 remains open only for its broader canonical hosted-to-source Ask/Tell, stale-fence, and intent-specific presentation ACs.

QA post-fix matrix: remaining live gap is canonical hosted-to-source Tell then Ask under real fence rotation; Tell must reconcile delivered-only once, Ask reply once, and stale-fence retry must not duplicate.

Reviewer found prompt completion ACK and replay-prompt ACK directly reuse pending stale fence instead of requestDeliveryAckWithFenceRefresh. Assigned implementation and exactly-once identical-payload tests.

Implemented prompt completion and replay-prompt ACK through the common fence-refresh path with identical payload and one bounded retry (babc3a3). Added exactly-once stale/fresh fence regression. Fresh hosted-to-source live acceptance remains.

Hosted A→B ActorMessageRequest regression reproduced on origin/main a57222a path: alpha attached to bravo, alpha Tell/Ask admitted through service ActorMessageRequest -> SendActorTask -> credit -> ActorTask, bravo received Tell and Ask/thread, bravo ACK completed the Ask, but alpha's fresh request-id completion retry failed with source mutation sequence collision. Fixed source AgentActor replay to accept durable retained source mutations by logical dedupe/chain/sequence/target/mode/capability/payload fingerprint even when the transport request_id rotates; raw BridgeIntent and retired Prompt/TaskLifecycle remain rejected. Added hosted A→B service regression and hosted bridge sequencer fresh-process no-duplicate coverage. Gates: go test ./internal/actors ./internal/service; service npm ci/codegen verify/go test -race ./.../go vet ./.../npm test; hosted-pi-bridge npm ci + npm test; git diff --check. Initial service npm test failed before extension dependencies were installed; rerun passed after npm ci in hosted-pi-bridge.

Follow-up lifecycle fix: hosted-pi-bridge lifecycle reporting now retries only BridgeLifecycleResponse accepted=false reason exactly 'durable persistence is busy' with bounded backoff, identical lifecycle payload, and identical fence/identity. Protocol has no typed rejection code for lifecycle responses, so the classifier is deliberately bound to the exact existing daemon reason and documents that compatibility constraint. Authorization/fence/incarnation/unknown-event/non-busy lifecycle rejections remain fatal. Added extension retry/exhaustion/non-busy tests and actor durable-persistence race test proving READY receives transient busy during an in-flight durable mutation, identical READY retry converges after fsync, and same-incarnation ready binding does not regress from Ready/BridgeReady. Gates passed: services/subagents npm ci/codegen verify/go test -race ./.../go vet ./.../npm test; hosted-pi-bridge npm ci + npm test 43/43; git diff --check.

Urgent presentation-ACK fix: added protobuf FrontendCompletionAckRequest/Response and generated Go/TS bindings; actor-client now sends ACK only after conversation.complete returns presented and the projection/custom message succeeds. Service authenticates only client:* source sessions in their current generation, validates exact completion key/request/dedupe/chain/source sequence/frame sequence, and forwards MarkFrontendCompletionDelivered to the source AgentActor. Source AgentActor durably removes the pending completion from ReceivedTaskCompletions before acknowledging; duplicate ACK after durable removal is idempotent, wrong completion identity fails closed. Broker no longer treats WebSocket writer enqueue as delivery authority, so reconnect/restart replay continues until durable frontend ACK. Tests cover enqueue-without-presentation replay on reconnect, duplicate ACK idempotence, forged ACK rejection, three consecutive completions with per-frame durable ACK, actor durable ACK removal, and actor-client exact ACK payload after durable presentation. Gates passed: actor-client npm test 43/43; hosted-pi-bridge npm test 43/43; services/subagents npm ci/codegen verify/go test -race ./.../go vet ./.../npm test; git diff --check.

Live actor1→actor2 E2E exposed a daemon crash at 12:33:48: async bridge push raced connection teardown and sent on a closed per-connection writer channel (Service.pushBridgeToSession, service.go:1771). Fixed by making the connection closed signal own writer-loop shutdown and deliberately leaving the connection-scoped sender channel open, so stale bounded push continuations select closed rather than panicking the process. Focused service race suite and vet pass; fresh post-deploy relay E2E remains required.

Fresh relay E2E then exposed zero bridge-run-counter ACKs: prompt injection could receive a stale agent_settled from the prior run before its follow-up agent_start, causing PromptTaskCoordinator to finalize with run counter 0 and fail exact thread ACK identity forever. Coordinator now binds pending work only to the first post-injection agent_start, records agent_end only for that run, and ignores stale settlement until the correlated run ends. Added coarse payload-free ACK mismatch-class diagnostics and integration coverage for start/end/settled ordering. Hosted bridge 43/43 passes; fresh live relay remains required after runtime reincarnation.

Cold-start probe still produced run-counter zero because this hosted Pi surface can omit agent_start for injected follow-up work. Added a strict fallback: agent_end may allocate/bind the run counter only when its user-message set contains the exact injected prompt text; unrelated prior runs and stale settlement remain unable to claim the pending thread. Added negative unrelated-run and positive omitted-agent_start coverage; hosted bridge 44/44 passes.

Fresh live relay exposed a remaining queueing defect: client displayed regular deliveries 5 and 6, but AckCursor stayed 4 and relay B remained stored_pending_credit. RegularDeliveryCoordinator awaits sendFollowUp inside its serialized tail; on this Pi surface that thenable spans the triggered model turn, so the active Ask blocks a following Tell's durable ACK despite presentation.

Six-actor TASK-26 dogfood reproduced the simpler blocker: nested hosted actor_ask returns admission/pending to the supervisor model, terminal results are not injected as same-thread continuations, later rounds advance prematurely, and queued prompts enter persistent run-counter ACK rejection. TASK-19 now owns the communication correction before TASK-26 retry.

Simpler dogfood worker completed commit 9926ad9 in task-19-comms-correction, but the requesting client received no terminal ActorTaskCompleted wake and did not automatically advance to review; operator had to report visible completion. This independently reproduces the missing completion wake. After authoritative git evidence was inspected, reviewer Ask sequence 57 was admitted for independent review of 9926ad9.

Worker ActorTaskCompleted for sequence 56 eventually presented with commit 9926ad9725b27db9ada90e019705affe00ec16b9 and full gate evidence, but only after the operator had already observed completion and prompted the client. This confirms current deployed completion wake remains delayed; reviewer sequence 57 was already admitted and remains the active next barrier.

Independent reviewer completed sequence 57 and BLOCKED 9926ad9: continuation correlation lacks an exact durable parent-child identity and consumed-completion marker, so a stale same-chain completion can resume the wrong parent turn. Focused Go/bridge suites passed but do not cover this ambiguity. Finding routed back to retained worker through corrective Ask sequence 58 with required parent epoch/lease/turn/delivery + child completion tuple, consumed-before-wake persistence, and adversarial stale/reordered/restart tests.

Worker corrective commit 2b98ce8 completed sequence 58 with exact persisted parent-child wait identity and adversarial stale/wrong-lease/consumed/restart coverage; worker reports codegen, Go race/vet/protocol, hosted bridge 45/45, and diff gates pass. Independent re-review immediately admitted as sequence 59 over full d7bf506..2b98ce8 diff.

Second independent review BLOCKED 2b98ce8. Completion matching compares persisted wait identity to mutable global scheduler epoch/lease, so unrelated thread scheduling while the parent waits can make the exact child completion permanently unmatchable. Tests remain helper-seeded rather than real nested hosted ActorTask E2E. Corrective worker Ask sequence 60 requires immutable parent dispatch identity, interleaved-scheduler liveness test, full actor/service nested path, and durable one-outstanding-child admission barrier.

After worker prompt ACK sequence 10 entered persistent run-counter rejection, exact worker and stale relay B were stopped as unrecoverable recovery to halt retry storms. Integrated reviewed implementation commits through c5e2f70 and added production service-path nested hosted Ask test: source→parent prompt, typed parent continuation, one-outstanding-child rejection, child terminal ActorTaskCompleted, automatic exact parent continuation, and exactly-one replay assertion. Focused count=3, actor/service race, vet, codegen, protocol 6/6, hosted bridge 45/45, actor-client 44/44, and diff checks pass.

Nested hosted Ask correction approved at 583799b. Independent reviewer APPROVE covered exact immutable parent/child identity, consumed-before-wake, narrowly scoped same-run next-turn ACKs, empty-settlement introspection recovery, exact transient-busy retry, delivery-sequence replay identity, nested Tell independence, and fail-closed retired model paths. Full Go race/vet/codegen/protocol, hosted bridge 47/47, actor-client 44/44, focused nested/reconnect count=5, capabilities, and diff checks passed. Live v11 proof completed client→worker→reviewer→worker→client with REVIEW_OK_W11 then WORKER_AND_REVIEW_OK_W11 in the same durable parent thread; source receipt 74 was terminal Completed=true and daemon logs contained no ACK identity, run-counter, stale-credit, or delivery rejection warnings. A later PC restart restored the daemon active from persisted state; fresh post-reboot canonical source Tell/Ask evidence remains the next live gate.

Post-PC-restart canonical-source v12 live gate exposed two remaining release blockers. SOURCE_TELL_OK_V12 presented, but its sequence 5 ACK repeatedly failed with `delivery acknowledgement fence rejected`; self-reattach created a fresh durable fence and the immediate ACK raced persistence busy. The following same-parent-chain Ask was repeatedly target-rejected because regular interactive admission incorrectly treated chain_id as one-mutation authority. Fixed regular interactive targets to allow distinct request/dedupe/mutation identities in one parent chain while retaining the legacy hosted provenance guard. Regular client ACK now retries only exact `durable persistence is busy` after stale-fence reattach, bounded, without widening auth/fence errors. Added same-chain regular delivery and fresh-fence persistence-race regressions. Full Go race/vet/codegen/protocol, hosted bridge 47/47, actor-client 45/45, capabilities, and diff checks pass. v12 was explicitly stopped after the unrecoverable rejection loop; fresh deployment/restart E2E is required.

Independent reviewer v13 APPROVED 0dc938f with no findings. Focused/full Go race, vet, codegen, protocol, actor-client, capabilities, and diff gates passed; only known environment-only tmux/stylua/scratch-template checks were unavailable. Built and deployed the daemon, atomically applied the actor-client extension, and restarted the daemon active. Because actor-client code is loaded at terminal startup, a full Pi process restart (not /reload) is required before fresh v13 source Tell→Ask E2E.

Fresh v15 after an actual terminal Pi restart still failed: stale regular prompt sequence 5 rejected ACK identity, kept AckCursor=4, later Tell/Ask accumulated at sequences 9-12, and Ask redrive hit credit_reservation_missing. v15 was explicitly stopped. The prior test strategy is rejected as insufficient; implementation now requires a real persisted-restart production-path regression before any further live claim.

Implemented deterministic stale regular-prompt reincarnation correction. Actor-client now persists `settled` outcome before ACK; an injected/unsettled marker restored by a new executor is terminally failed as abandoned, never reinjected or fabricated successful, and reuses the identical settlement after response loss/restart. ACK responses now include bounded typed rejection_code; client retry policy uses only typed fence/authorization and exact persistence_busy classes. Added a real persisted daemon restart service test covering old prompt identity, new self attachment, stale fence rejection, bounded busy convergence, contiguous retirement, later same-chain Tell+Ask, second restart no replay; race count=20 passed. Node tests prove durable settlement before failed ACK, identical replay, and second-restart exactly-once. Full Go race rerun passed; initial unrelated known TempDir cleanup race in TestPushedAndPolledAskDeliveriesCarryAcknowledgementIdentity passed on full rerun.

Independent reviewer v16 APPROVED 1cdf3f5 with no findings after actor-client 45/45, hosted bridge 47/47, full service codegen/race/vet/protocol, focused persisted-restart race count=20, capabilities, and diff checks. Built/deployed daemon and atomically applied actor-client plus generated hosted bridge boundary; daemon restarted active. One full terminal Pi process restart is required to load the new marker/rejection-code behavior and retire the existing stale sequence 5 before the final live Tell→Ask gate.

First post-deploy reincarnation exposed the exact missing fixture dimension: sequence 5 passed fresh ACK validation, but commit returned typed `identity_commit` because contiguous draining reached pre-restart buffered ACK 6. Durable AckGapRecord intentionally omits transient session handle/fence, while commitAck incorrectly re-required them after restart and rolled back the valid head ACK. Corrected commit to revalidate only immutable delivery/thread/runtime shape for ACKs already authenticated before durable gap acceptance; scope token and mutation record checks still gate retirement. Expanded the persisted restart test to ACK a later Tell into the gap before daemon restart, then prove the abandoned head plus authenticated gap retire atomically, later same-chain Tell+Ask converge, and second restart replays nothing. Focused race count=20 passes.

Independent reviewer v17 APPROVED da9aecc with no findings. Full codegen/race/vet/protocol, actor-client 45/45, hosted bridge 47/47, and focused persisted-gap restart race count=20 pass. Deployed rebuilt daemon and restarted active; current terminal already runs the 1cdf3f5 actor-client, so daemon replay should consume its durable settled marker and retire sequence 5 plus authenticated gaps without another terminal restart.

After deploying da9aecc, the already-running actor-client remained disconnected from the daemon restart, exposing the final AC3 gap: reconnect occurred only on a later tool call/process restart. Added a bounded 500ms connection reconciler guarded by one bootstrap, stable generation/context fencing, timer cleanup/unref, and full client/session/fence reset. Reviewer v18 APPROVED 88a5f6a; actor-client 46/46 and focused service gates pass. Atomically deployed actor-client. One final terminal process restart loads the reconciler; subsequent daemon restarts no longer require operator intervention.

Lifecycle hardening after cursor recovery: sequence 10 became the active regular Ask, revealing that RegularDeliveryCoordinator.agentEnd previously accepted any subsequent terminal turn. Bound settlement to a message set containing the exact injected user prompt (same strict omitted-agent_start fallback used by hosted prompts); unrelated operator turns no longer settle Actor Ask. Added regression; actor-client 47/47 passes. Deployed source, requiring one terminal restart to load this final correlation guard; restored sequence 10 will then retire as prior-executor abandonment and sequence 12 can be handled as the next exact prompt.
<!-- SECTION:NOTES:END -->
