import { createActor, fromCallback, fromPromise, setup, type AnyActorRef, type AnyActorLogic } from "xstate";

export type SupervisorStrategy = "one_for_one" | "one_for_all" | "rest_for_one";
export type RestartPolicy = "permanent" | "transient" | "temporary";
export type ChildState = "stopped" | "running" | "backoff" | "circuit-open";
export type ChildDelivery =
  | { delivered: true; childId: string; state: "running" }
  | { delivered: false; childId: string; state: ChildState | "missing" | "supervisor-stopped"; reason: string };

export function callbackChildLogic(start: () => void, stop: () => void): AnyActorLogic {
  return fromCallback(() => { start(); return stop; });
}
export function promiseChildLogic(run: (input: unknown) => Promise<void>): AnyActorLogic {
  return fromPromise(({ input }) => run(input));
}

export interface ChildSpec {
  id: string;
  logic: AnyActorLogic;
  input?: unknown;
  restart: RestartPolicy;
}

export interface RestartPolicyConfig {
  maxRestarts: number;
  withinMs: number;
  initialBackoffMs: number;
  maxBackoffMs: number;
  jitterRatio: number;
}

export interface FailureReceipt {
  schemaVersion: 1;
  supervisorId: string;
  childId: string;
  reason: string;
  abnormal: boolean;
  occurredAt: number;
  affectedChildren: string[];
  restartAttempt: number;
  decision: "ignore" | "restart" | "circuit-open" | "escalate";
}

interface ChildRecord {
  spec: ChildSpec;
  state: ChildState;
  restarts: number[];
  attempt: number;
  ref?: AnyActorRef;
  suppressExit?: boolean;
}

export interface SupervisorInput {
  id: string;
  strategy: SupervisorStrategy;
  children: ChildSpec[];
  policy?: Partial<RestartPolicyConfig>;
  now?: () => number;
  random?: () => number;
  schedule?: (delayMs: number, event: SupervisorEvent) => void;
  receipt?: (receipt: FailureReceipt) => void;
  escalate?: (receipt: FailureReceipt) => void;
  signal?: (event: SupervisorEvent) => void;
}

export type SupervisorEvent =
  | { type: "SUPERVISOR.START" }
  | { type: "CHILD.ADD"; spec: ChildSpec }
  | { type: "CHILD.REMOVE"; childId: string }
  | { type: "CHILD.SEND"; childId: string; event: unknown }
  | { type: "SUPERVISOR.STOP" }
  | { type: "CHILD.FAILED"; childId: string; reason: string; abnormal: boolean; at?: number }
  | { type: "CHILD.EXITED"; childId: string; reason: string; abnormal: boolean; at?: number }
  | { type: "SUPERVISOR.RESTART_DUE"; childIds: string[] };

interface SupervisorContext {
  id: string;
  strategy: SupervisorStrategy;
  order: string[];
  children: Record<string, ChildRecord>;
  policy: RestartPolicyConfig;
  now: () => number;
  random: () => number;
  schedule: (delayMs: number, event: SupervisorEvent) => void;
  receipt: (receipt: FailureReceipt) => void;
  escalate: (receipt: FailureReceipt) => void;
  signal: (event: SupervisorEvent) => void;
  stopping: boolean;
}

const DEFAULT_POLICY: RestartPolicyConfig = {
  maxRestarts: 3,
  withinMs: 10_000,
  initialBackoffMs: 100,
  maxBackoffMs: 10_000,
  jitterRatio: 0.2,
};

function affected(context: SupervisorContext, failedId: string): string[] {
  const index = context.order.indexOf(failedId);
  if (index < 0) return [];
  if (context.strategy === "one_for_one") return [failedId];
  if (context.strategy === "one_for_all") return [...context.order];
  return context.order.slice(index);
}

function shouldRestart(record: ChildRecord, abnormal: boolean): boolean {
  return record.spec.restart === "permanent" || (record.spec.restart === "transient" && abnormal);
}

function stopRecord(record: ChildRecord): void {
  if (record.ref) {
    record.suppressExit = true;
    record.ref.stop();
    record.ref = undefined;
  }
  if (record.state !== "circuit-open") record.state = "stopped";
}

function startRecord(context: SupervisorContext, record: ChildRecord): void {
  if (record.state === "circuit-open" || record.ref) return;
  const ref = createActor(record.spec.logic, { id: record.spec.id, input: record.spec.input });
  record.ref = ref;
  record.suppressExit = false;
  record.state = "running";
  ref.subscribe({
    error: (error) => context.signal({ type: "CHILD.FAILED", childId: record.spec.id, reason: error instanceof Error ? error.message : String(error), abnormal: true, at: context.now() }),
    complete: () => { if (!record.suppressExit) context.signal({ type: "CHILD.EXITED", childId: record.spec.id, reason: "supervised child completed normally", abnormal: false, at: context.now() }); },
  });
  ref.start();
}

export const supervisorMachine = setup({
  types: {} as { context: SupervisorContext; input: SupervisorInput; events: SupervisorEvent },
  actions: {
    startAll: ({ context }) => {
      context.stopping = false;
      for (const id of context.order) startRecord(context, context.children[id]);
    },
    stopAll: ({ context }) => {
      context.stopping = true;
      for (const id of [...context.order].reverse()) stopRecord(context.children[id]);
    },
    restartDue: ({ context, event }) => {
      if (event.type !== "SUPERVISOR.RESTART_DUE" || context.stopping) return;
      for (const id of event.childIds) { const record = context.children[id]; if (record) startRecord(context, record); }
    },
    addChild: ({ context, event }) => {
      if (event.type !== "CHILD.ADD") return;
      if (context.children[event.spec.id]) throw new Error(`duplicate supervised child ${event.spec.id}`);
      context.order.push(event.spec.id);
      context.children[event.spec.id] = { spec: event.spec, state: "stopped", restarts: [], attempt: 0 };
      if (!context.stopping) startRecord(context, context.children[event.spec.id]);
    },
    removeChild: ({ context, event }) => {
      if (event.type !== "CHILD.REMOVE") return;
      const record = context.children[event.childId]; if (!record) return;
      stopRecord(record); delete context.children[event.childId];
      context.order = context.order.filter((id) => id !== event.childId);
    },
    sendChild: ({ context, event }) => {
      if (event.type !== "CHILD.SEND") return;
      context.children[event.childId]?.ref?.send(event.event as never);
    },
    handleExit: ({ context, event }) => {
      if (event.type !== "CHILD.FAILED" && event.type !== "CHILD.EXITED") return;
      const failed = context.children[event.childId];
      if (!failed) return;
      const at = event.at ?? context.now();
      const targets = affected(context, event.childId);
      if (!shouldRestart(failed, event.abnormal) || context.stopping) {
        stopRecord(failed);
        context.receipt({ schemaVersion: 1, supervisorId: context.id, childId: event.childId, reason: event.reason,
          abnormal: event.abnormal, occurredAt: at, affectedChildren: targets, restartAttempt: failed.attempt, decision: "ignore" });
        return;
      }
      for (const id of [...targets].reverse()) stopRecord(context.children[id]);
      failed.restarts = failed.restarts.filter((time) => at - time <= context.policy.withinMs);
      if (failed.restarts.length === 0) failed.attempt = 0;
      failed.restarts.push(at);
      failed.attempt += 1;
      if (failed.restarts.length > context.policy.maxRestarts) {
        for (const id of targets) context.children[id].state = "circuit-open";
        const receipt: FailureReceipt = { schemaVersion: 1, supervisorId: context.id, childId: event.childId,
          reason: event.reason, abnormal: event.abnormal, occurredAt: at, affectedChildren: targets,
          restartAttempt: failed.attempt, decision: "circuit-open" };
        context.receipt(receipt);
        context.escalate({ ...receipt, decision: "escalate" });
        return;
      }
      const exponential = Math.min(context.policy.maxBackoffMs, context.policy.initialBackoffMs * 2 ** (failed.attempt - 1));
      const jitter = exponential * context.policy.jitterRatio * (context.random() * 2 - 1);
      const delay = Math.max(0, Math.round(exponential + jitter));
      for (const id of targets) context.children[id].state = "backoff";
      context.receipt({ schemaVersion: 1, supervisorId: context.id, childId: event.childId, reason: event.reason,
        abnormal: event.abnormal, occurredAt: at, affectedChildren: targets, restartAttempt: failed.attempt, decision: "restart" });
      context.schedule(delay, { type: "SUPERVISOR.RESTART_DUE", childIds: targets });
    },
  },
}).createMachine({
  id: "otp-supervisor",
  initial: "idle",
  context: ({ input }) => ({
    id: input.id,
    strategy: input.strategy,
    order: input.children.map((child) => child.id),
    children: Object.fromEntries(input.children.map((spec) => [spec.id, { spec, state: "stopped", restarts: [], attempt: 0 }])),
    policy: { ...DEFAULT_POLICY, ...input.policy },
    now: input.now ?? Date.now,
    random: input.random ?? Math.random,
    schedule: input.schedule ?? ((delay, event) => { const timer = setTimeout(() => {}, delay); timer.unref?.(); void event; }),
    receipt: input.receipt ?? (() => {}),
    escalate: input.escalate ?? (() => {}),
    signal: input.signal ?? (() => {}),
    stopping: false,
  }),
  states: {
    idle: { on: { "SUPERVISOR.START": { target: "running", actions: "startAll" } } },
    running: {
      on: {
        "CHILD.ADD": { actions: "addChild" },
        "CHILD.REMOVE": { actions: "removeChild" },
        "CHILD.SEND": { actions: "sendChild" },
        "CHILD.FAILED": { actions: "handleExit" },
        "CHILD.EXITED": { actions: "handleExit" },
        "SUPERVISOR.RESTART_DUE": { actions: "restartDue" },
        "SUPERVISOR.STOP": { target: "stopped", actions: "stopAll" },
      },
    },
    stopped: { type: "final" },
  },
});

export function createSupervisorActor(input: SupervisorInput) {
  let actor: ReturnType<typeof createActor<typeof supervisorMachine>>;
  const schedule = input.schedule ?? ((delay: number, event: SupervisorEvent) => {
    const timer = setTimeout(() => actor.send(event), delay);
    timer.unref?.();
  });
  const signal = input.signal ?? ((event: SupervisorEvent) => actor.send(event));
  actor = createActor(supervisorMachine, { input: { ...input, schedule, signal } });
  return Object.assign(actor, {
    sendChild(childId: string, event: unknown): ChildDelivery {
      const snapshot = actor.getSnapshot();
      if (!snapshot.matches("running")) return { delivered: false, childId, state: "supervisor-stopped", reason: `supervisor ${input.id} is stopped` };
      const record = snapshot.context.children[childId];
      if (!record) return { delivered: false, childId, state: "missing", reason: `supervised child ${childId} is unavailable` };
      if (record.state !== "running" || !record.ref) return { delivered: false, childId, state: record.state, reason: `supervised child ${childId} is ${record.state}` };
      record.ref.send(event as never);
      return { delivered: true, childId, state: "running" };
    },
    childState(childId: string): ChildState | "missing" {
      return actor.getSnapshot().context.children[childId]?.state ?? "missing";
    },
  });
}

/** Durable form: desired child specifications and restart counters only; actor refs are intentionally omitted. */
export function durableSupervisorSnapshot(snapshot: ReturnType<typeof createSupervisorActor>["getSnapshot"] extends () => infer S ? S : never) {
  const context = snapshot.context as SupervisorContext;
  return {
    schemaVersion: 1,
    supervisorId: context.id,
    strategy: context.strategy,
    order: [...context.order],
    children: context.order.map((id) => {
      const child = context.children[id];
      return { id, restart: child.spec.restart, state: child.state, restarts: [...child.restarts], attempt: child.attempt };
    }),
  };
}
