import { assign, setup } from "xstate";
import { incomingCard, outgoingCard, completeAsk } from "./conversation.ts";
import { digestPresentation, rememberCompletion } from "./dedupe.ts";
import type { ActorClientProjectionEvent } from "./events.ts";
import { projectSnapshot } from "./layout.ts";
import { restorePending } from "./pending.ts";
import { reduceRoster, initialRosterProjection } from "./roster.ts";
import { sanitizeLabel, sanitizeText } from "./sanitize.ts";
import type { ProjectionContext } from "./types.ts";

export function initialProjectionContext(): ProjectionContext {
  const context: ProjectionContext = { sessionGeneration: 0, connection: "disconnected", transcriptSeq: 0, eventSeq: 0, replayAuthority: false, draft: "", turnAdmission: { state: "admission_required" }, executor: { seenLifecycleEvents: new Set(), pendingCommands: new Map() }, affordances: { continuations: new Map(), introspections: new Map() }, pendingPresentation: new Map(), acknowledgedPresentations: new Set(), presentationAckOutbox: [], roster: initialRosterProjection(), pending: new Map(), cards: new Map(), completions: new Map(), presented: new Set(), snapshot: { connection: "disconnected", cards: [], width: 80, overflow: 0, themeRevision: 0, inputState: "admission_required" }, maxCards: 512 };
  context.snapshot = projectSnapshot(context, 80, 0);
  return context;
}

function sameExecutor(a: ProjectionContext["executor"]["current"], b: ProjectionContext["executor"]["current"]): boolean { return !!a && !!b && a.actorEpoch === b.actorEpoch && a.executorId === b.executorId && a.executorGeneration === b.executorGeneration; }
function lifecycleKey(executor: NonNullable<ProjectionContext["executor"]["current"]>, lifecycleSeq: number): string { return `${executor.actorEpoch}:${executor.executorId}:${executor.executorGeneration}:${lifecycleSeq}`; }
function isConnected(context: ProjectionContext): boolean { return context.connection === "connected" || context.connection === "reconnecting" || context.connection === "degraded"; }
function isAuthoritative(context: ProjectionContext, actorEpoch: string, eventSeq: number): boolean { return context.replayAuthority && isConnected(context) && (!context.actorEpoch || actorEpoch === context.actorEpoch) && eventSeq > context.eventSeq; }
function presentationKey(value: { presentationId: string; turnId: string; transcriptSeq: number; actorEpoch: string }): string { return `${value.actorEpoch}:${value.turnId}:${value.transcriptSeq}:${value.presentationId}`; }
function replaceAffordances(event: Extract<ActorClientProjectionEvent, { type: "ACTOR.SNAPSHOT" }>): ProjectionContext["affordances"] {
  return { continuations: new Map((event.availableContinuations ?? []).filter((item) => item.actorEpoch === event.actorEpoch && item.eventSeq <= event.eventSeq).map((item) => [item.continuationId, { turnId: item.turnId, label: sanitizeLabel(item.label, 64) ?? "Continue", mode: item.mode, actorEpoch: item.actorEpoch, eventSeq: item.eventSeq }])), introspections: new Map((event.availableIntrospections ?? []).filter((item) => item.actorEpoch === event.actorEpoch && item.eventSeq <= event.eventSeq).map((item) => [item.introspectionId, { scope: item.scope, privacyNotice: sanitizeText(item.privacyNotice, 120), actorEpoch: item.actorEpoch, eventSeq: item.eventSeq }])) };
}
function replacePresentation(context: ProjectionContext, event: Extract<ActorClientProjectionEvent, { type: "ACTOR.SNAPSHOT" }>): ProjectionContext["pendingPresentation"] { return new Map((event.pendingPresentation ?? []).filter((item) => item.actorEpoch === event.actorEpoch && item.transcriptSeq <= event.transcriptSeq && !context.acknowledgedPresentations.has(presentationKey(item))).map((item) => [presentationKey(item), { presentationId: item.presentationId, turnId: item.turnId, transcriptSeq: item.transcriptSeq, actorEpoch: item.actorEpoch, requirement: sanitizeLabel(item.requirement, 80) ?? "presentation_required" }])); }

export function reduceProjection(context: ProjectionContext, event: ActorClientProjectionEvent): ProjectionContext {
  let next: ProjectionContext = context;
  const withSnapshot = (value: ProjectionContext) => ({ ...value, snapshot: projectSnapshot(value) });
  switch (event.type) {
    case "SESSION.START": return withSnapshot({ ...initialProjectionContext(), sessionGeneration: event.generation });
    case "SESSION.RESET": return withSnapshot({ ...initialProjectionContext(), sessionGeneration: event.generation });
    case "TRANSPORT.CONNECTING": return withSnapshot({ ...context, connection: "connecting" });
    case "TRANSPORT.AUTHENTICATING": return withSnapshot({ ...context, connection: "authenticating" });
    case "TRANSPORT.SUBSCRIBING_ROSTER": return withSnapshot({ ...context, connection: "subscribingRoster" });
    case "TRANSPORT.CONNECTED": return withSnapshot({ ...context, connection: "connected" });
    case "TRANSPORT.RECONNECTING": return withSnapshot({ ...context, connection: "reconnecting" });
    case "TRANSPORT.CLOSING": return withSnapshot({ ...context, connection: "closing" });
    case "TRANSPORT.DISCONNECTED": return withSnapshot({ ...context, connection: "disconnected" });
    case "TRANSPORT.DEGRADED": return withSnapshot({ ...context, connection: "degraded", roster: { ...context.roster, degradedReason: sanitizeText(event.reason, 120) } });
    case "ROSTER.FRAME": return withSnapshot({ ...context, connection: "connected", roster: reduceRoster(context.roster, event) });
    case "TASK.ADMITTED": return withSnapshot({ ...context, pending: restorePending(context.pending, event.pending) });
    case "CLIENT.DRAFT.SET": return withSnapshot({ ...context, draft: event.draft });
    case "USER_TURN.ADMISSION.REQUESTED": {
      if (context.actorEpoch && event.actorEpoch !== context.actorEpoch) return context;
      if (!["admission_required", "blocked"].includes(context.turnAdmission.state)) return context;
      if (context.actorEpoch && !context.replayAuthority) return context;
      const admittedEpoch = context.replayAuthority ? event.actorEpoch : undefined;
      return withSnapshot({ ...context, turnAdmission: { state: "admission_pending", proposedTurnId: event.proposedTurnId, actorEpoch: admittedEpoch, baseTranscriptSeq: event.baseTranscriptSeq, idempotencyKey: event.idempotencyKey } });
    }
    case "USER_TURN.ADMISSION.DECISION": {
      if (context.turnAdmission.state !== "admission_pending") return context;
      if (!context.actorEpoch || event.actorEpoch !== context.actorEpoch) return context;
      if (context.turnAdmission.actorEpoch !== event.actorEpoch) return context;
      if (context.turnAdmission.proposedTurnId !== event.proposedTurnId) return context;
      const state = event.decision === "admit" ? "admitted" : event.decision === "defer" ? "blocked" : "admission_required";
      return withSnapshot({ ...context, actorEpoch: event.actorEpoch, turnAdmission: { ...context.turnAdmission, state, proposedTurnId: event.proposedTurnId, actorEpoch: event.actorEpoch, admissionToken: event.decision === "admit" ? event.admissionToken : undefined, reason: sanitizeText(event.reason, 120) } });
    }
    case "USER_TURN.SUBMITTED": {
      const admission = context.turnAdmission;
      if (admission.state !== "admitted" || admission.proposedTurnId !== event.proposedTurnId || event.turnId !== admission.proposedTurnId || admission.actorEpoch !== event.actorEpoch || admission.admissionToken !== event.admissionToken || admission.idempotencyKey !== event.idempotencyKey) return context;
      return withSnapshot({ ...context, turnAdmission: { state: "executing", proposedTurnId: event.proposedTurnId, actorEpoch: event.actorEpoch, baseTranscriptSeq: admission.baseTranscriptSeq, idempotencyKey: event.idempotencyKey } });
    }
    case "ACTOR.SNAPSHOT": {
      if (context.actorEpoch && event.actorEpoch !== context.actorEpoch) return context;
      if (context.eventSeq && event.eventSeq <= context.eventSeq) return context;
      if (event.transcriptSeq < context.transcriptSeq) return context;
      const pendingCommands = new Map(context.executor.pendingCommands);
      for (const [key, command] of pendingCommands) if (!event.executor || !sameExecutor(command.executor, event.executor.ref)) pendingCommands.delete(key);
      const executor = event.executor ? { current: event.executor.ref, state: event.executor.state, lifecycleSeq: event.executor.lifecycleSeq, seenLifecycleEvents: new Set(context.executor.seenLifecycleEvents), pendingCommands } : { seenLifecycleEvents: new Set(context.executor.seenLifecycleEvents), pendingCommands: new Map() };
      return withSnapshot({ ...context, actorEpoch: event.actorEpoch, transcriptSeq: event.transcriptSeq, eventSeq: event.eventSeq, replayAuthority: true, executor, affordances: replaceAffordances(event), pendingPresentation: replacePresentation(context, event), turnAdmission: { state: context.turnAdmission.state === "executing" ? "executing" : "admission_required" } });
    }
    case "ACTOR.REINCARNATION": {
      if (!context.actorEpoch) return context;
      if (event.oldActorEpoch !== context.actorEpoch) return context;
      const state = event.recovery === "state_lost" ? "state_lost" : event.recovery === "transcript_replay_required" ? "replay_required" : "admission_required";
      const executor = event.currentExecutor ? { current: event.currentExecutor.ref, state: event.currentExecutor.state, lifecycleSeq: event.currentExecutor.lifecycleSeq, seenLifecycleEvents: new Set(context.executor.seenLifecycleEvents), pendingCommands: event.executorRecovery === "same_generation_valid" ? new Map(context.executor.pendingCommands) : new Map() } : { seenLifecycleEvents: new Set(context.executor.seenLifecycleEvents), pendingCommands: new Map() };
      return withSnapshot({ ...context, actorEpoch: event.newActorEpoch, transcriptSeq: 0, eventSeq: 0, replayAuthority: event.recovery === "lossless" && event.executorRecovery === "same_generation_valid", turnAdmission: { state }, executor, affordances: { continuations: new Map(), introspections: new Map() }, pendingPresentation: new Map() });
    }
    case "EXECUTOR.LIFECYCLE": {
      if (!context.replayAuthority || !context.actorEpoch || !context.executor.current) return context;
      if (event.executor.actorEpoch !== context.actorEpoch) return context;
      if (!sameExecutor(context.executor.current, event.executor)) return context;
      if (event.lifecycleSeq <= (context.executor.lifecycleSeq ?? -1)) return context;
      const key = lifecycleKey(event.executor, event.lifecycleSeq);
      if (context.executor.seenLifecycleEvents.has(key)) return context;
      const seenLifecycleEvents = new Set(context.executor.seenLifecycleEvents); seenLifecycleEvents.add(key);
      return withSnapshot({ ...context, actorEpoch: event.executor.actorEpoch, executor: { ...context.executor, current: event.executor, state: event.state, lifecycleSeq: event.lifecycleSeq, seenLifecycleEvents } });
    }
    case "EXECUTOR.COMMAND.REQUESTED": {
      if (!sameExecutor(context.executor.current, event.executor)) return context;
      const pendingCommands = new Map(context.executor.pendingCommands); pendingCommands.set(event.idempotencyKey, { executor: event.executor, command: event.command, idempotencyKey: event.idempotencyKey });
      return withSnapshot({ ...context, executor: { ...context.executor, pendingCommands } });
    }
    case "EXECUTOR.COMMAND.RESULT": {
      if (!sameExecutor(context.executor.current, event.executor)) return context;
      const pendingCommands = new Map(context.executor.pendingCommands); pendingCommands.delete(event.idempotencyKey);
      return withSnapshot({ ...context, executor: { ...context.executor, pendingCommands } });
    }
    case "PRESENTATION.REQUIRED": {
      if (!isAuthoritative(context, event.actorEpoch, event.eventSeq) || event.transcriptSeq < context.transcriptSeq) return context;
      const pendingPresentation = new Map(context.pendingPresentation);
      const key = presentationKey(event);
      if (context.acknowledgedPresentations.has(key)) return context;
      if ([...pendingPresentation.values()].some((item) => item.presentationId === event.presentationId && presentationKey(item) !== key)) return context;
      pendingPresentation.set(key, { presentationId: event.presentationId, turnId: event.turnId, transcriptSeq: event.transcriptSeq, actorEpoch: event.actorEpoch, requirement: sanitizeLabel(event.requirement, 80) ?? "presentation_required" });
      return withSnapshot({ ...context, eventSeq: event.eventSeq, pendingPresentation });
    }
    case "PRESENTATION.RENDERED": {
      const key = presentationKey(event);
      if (!context.pendingPresentation.has(key)) return context;
      if (context.acknowledgedPresentations.has(key)) return context;
      const pendingPresentation = new Map(context.pendingPresentation); pendingPresentation.delete(key);
      const acknowledgedPresentations = new Set(context.acknowledgedPresentations); acknowledgedPresentations.add(key);
      const ack = { type: "client.presentation.ack" as const, presentationId: event.presentationId, turnId: event.turnId, transcriptSeq: event.transcriptSeq, actorEpoch: event.actorEpoch, clientSessionId: event.clientSessionId, renderedAt: event.renderedAt, visibleRegion: event.visibleRegion };
      return withSnapshot({ ...context, pendingPresentation, acknowledgedPresentations, presentationAckOutbox: [...context.presentationAckOutbox, ack] });
    }
    case "CONTINUATION.AVAILABLE": {
      if (!isAuthoritative(context, event.actorEpoch, event.eventSeq)) return context;
      const continuations = new Map(context.affordances.continuations); continuations.set(event.continuationId, { turnId: event.turnId, label: sanitizeLabel(event.label, 64) ?? "Continue", mode: event.mode, actorEpoch: event.actorEpoch, eventSeq: event.eventSeq });
      return withSnapshot({ ...context, eventSeq: event.eventSeq, affordances: { ...context.affordances, continuations } });
    }
    case "INTROSPECTION.AVAILABLE": {
      if (!isAuthoritative(context, event.actorEpoch, event.eventSeq)) return context;
      const introspections = new Map(context.affordances.introspections); introspections.set(event.introspectionId, { scope: event.scope, privacyNotice: sanitizeText(event.privacyNotice, 120), actorEpoch: event.actorEpoch, eventSeq: event.eventSeq });
      return withSnapshot({ ...context, eventSeq: event.eventSeq, affordances: { ...context.affordances, introspections } });
    }
    case "TASK.BACKPRESSURED": {
      const cards = new Map(context.cards); cards.set(event.key, outgoingCard({ key: event.key, target: event.target, body: "", accepted: false, mode: "ask", reason: event.reason }));
      return withSnapshot({ ...context, cards });
    }
    case "TASK.COMPLETED": {
      const result = completeAsk({ ...event, cards: context.cards, pending: context.pending, completions: context.completions });
      return withSnapshot({ ...context, cards: result.cards, pending: result.pending, completions: result.completions });
    }
    case "DELIVERY.INCOMING.NOTE":
    case "DELIVERY.INCOMING.REQUEST": {
      if (context.cards.has(event.key)) return context;
      const cards = new Map(context.cards); cards.set(event.key, incomingCard({ key: event.key, source: event.source, body: event.body, request: event.type === "DELIVERY.INCOMING.REQUEST" }));
      return withSnapshot({ ...context, cards });
    }
    case "CONVERSATION.APPEND": {
      if (context.cards.has(event.card.key) || context.pending.has(event.card.key)) return context;
      const cards = new Map(context.cards); cards.set(event.card.key, event.card);
      return withSnapshot({ ...context, cards });
    }
    case "PRESENTATION.SUCCEEDED": {
      const completions = rememberCompletion(context.completions, event.key, event.digest);
      const presented = new Set(context.presented); presented.add(event.key);
      return withSnapshot({ ...context, completions, presented });
    }
    case "PRESENTATION.FAILED": return withSnapshot({ ...context, connection: "degraded", roster: { ...context.roster, degradedReason: sanitizeText(event.reason, 120) } });
    case "RESTORE.PENDING": return context.completions.has(event.pending.key) ? context : withSnapshot({ ...context, pending: restorePending(context.pending, event.pending) });
    case "RESTORE.COMPLETION": return withSnapshot({ ...context, pending: new Map([...context.pending].filter(([key, value]) => key !== event.key && value.requestId !== event.requestId)), completions: rememberCompletion(context.completions, event.key, event.digest) });
    case "VIEW.WIDTH": return { ...context, snapshot: projectSnapshot(context, Math.max(20, event.width), context.snapshot.themeRevision) };
    case "VIEW.THEME": return { ...context, snapshot: projectSnapshot(context, context.snapshot.width, event.revision) };
    default: return next;
  }
}

export function restoreProjectionEntries(context: ProjectionContext, entries: readonly any[]): ProjectionContext {
  let next = context;
  const completions: any[] = [];
  for (const entry of entries) {
    const message = entry?.message ?? entry;
    const customType = entry?.customType ?? message?.customType;
    const data = entry?.data ?? entry?.details ?? message?.details;
    if (customType === "actor-client-ask-pending" && typeof data?.key === "string") next = reduceProjection(next, { type: "RESTORE.PENDING", pending: { ...data, hidden: true } });
    if (customType === "actor-client-ask-completion" && typeof data?.key === "string") completions.push(data);
  }
  for (const data of completions) next = reduceProjection(next, { type: "RESTORE.COMPLETION", key: data.key, digest: data.terminalDigest ?? digestPresentation(data), requestId: data.requestId });
  return next;
}

export const actorClientProjectionMachine = setup({ types: {} as { context: ProjectionContext; events: ActorClientProjectionEvent } }).createMachine({
  id: "actor-client-projection",
  context: () => initialProjectionContext(),
  initial: "active",
  states: { active: {} },
  on: { "*": { actions: assign(({ context, event }) => reduceProjection(context, event as ActorClientProjectionEvent)) } },
});

export function createProjectionActorOptions() { return actorClientProjectionMachine; }
