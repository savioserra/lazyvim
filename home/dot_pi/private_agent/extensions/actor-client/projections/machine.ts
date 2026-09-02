import { assign, setup } from "xstate";
import { incomingCard, outgoingCard, completeAsk } from "./conversation.ts";
import { rememberCompletion } from "./dedupe.ts";
import type { ActorClientProjectionEvent } from "./events.ts";
import { projectSnapshot } from "./layout.ts";
import { restorePending } from "./pending.ts";
import { reduceRoster, initialRosterProjection } from "./roster.ts";
import { sanitizeText } from "./sanitize.ts";
import type { ProjectionContext } from "./types.ts";

export function initialProjectionContext(): ProjectionContext {
  const context: ProjectionContext = { sessionGeneration: 0, connection: "disconnected", roster: initialRosterProjection(), pending: new Map(), cards: new Map(), completions: new Map(), presented: new Set(), snapshot: { connection: "disconnected", cards: [], width: 80, overflow: 0, themeRevision: 0 }, maxCards: 512 };
  context.snapshot = projectSnapshot(context, 80, 0);
  return context;
}

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
    case "RESTORE.COMPLETION": return withSnapshot({ ...context, pending: new Map([...context.pending].filter(([key]) => key !== event.key)), completions: rememberCompletion(context.completions, event.key, event.digest) });
    case "VIEW.WIDTH": return { ...context, snapshot: projectSnapshot(context, Math.max(20, event.width), context.snapshot.themeRevision) };
    case "VIEW.THEME": return { ...context, snapshot: projectSnapshot(context, context.snapshot.width, event.revision) };
    default: return next;
  }
}

export const actorClientProjectionMachine = setup({ types: {} as { context: ProjectionContext; events: ActorClientProjectionEvent } }).createMachine({
  id: "actor-client-projection",
  context: () => initialProjectionContext(),
  initial: "active",
  states: { active: {} },
  on: { "*": { actions: assign(({ context, event }) => reduceProjection(context, event as ActorClientProjectionEvent)) } },
});

export function createProjectionActorOptions() { return actorClientProjectionMachine; }
