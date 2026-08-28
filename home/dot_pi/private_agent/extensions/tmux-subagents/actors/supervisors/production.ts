import { randomUUID } from "node:crypto";
import { fromCallback, fromPromise, type AnyActorLogic } from "xstate";
import type { Projection } from "../../domain/projection.ts";
import { createSupervisorActor, type ChildDelivery, type FailureReceipt, type RestartPolicy, type SupervisorEvent } from "./supervisor.ts";

export type ProductionEffectEvent =
  | { type: "PROJECTION.PUBLISH"; projection: Projection }
  | { type: "TOPOLOGY.EXECUTE"; requestId: string; operation: () => Promise<unknown> }
  | { type: "SUPERVISOR.STOP" };

export interface RendererLifecycleSpec {
  childId: string;
  restart: RestartPolicy;
  run: (signal: AbortSignal) => Promise<void>;
}

export interface ProductionEffects {
  startIpc: () => Promise<void>;
  stopIpc: () => Promise<void>;
  reconcile: () => Promise<void>;
  publishProjection: (projection: Projection) => Promise<void>;
  intervalMs: number;
  topologyTimeoutMs?: number;
  receipt?: (receipt: FailureReceipt) => void;
  escalate?: (receipt: FailureReceipt) => void;
}

interface PendingTopologyRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

/** Owns production IPC, topology, projection, and every renderer pane lifecycle. */
export function createProductionSupervisorActor(effects: ProductionEffects) {
  let supervisor: ReturnType<typeof createSupervisorActor>;
  let stopped = false; let ipcCleanup = Promise.resolve(); const ipcStopFailures: Error[] = [];
  const pendingTopology = new Map<string, PendingTopologyRequest>();
  const topologyTimeoutMs = effects.topologyTimeoutMs ?? Math.max(10_000, effects.intervalMs * 4);
  const errorOf = (value: unknown) => value instanceof Error ? value : new Error(String(value));
  const rejectTopologyPending = (reason: unknown) => {
    const error = errorOf(reason);
    for (const pending of pendingTopology.values()) { clearTimeout(pending.timer); pending.reject(error); }
    pendingTopology.clear();
  };
  const settleTopology = (requestId: string, outcome: { value: unknown } | { error: unknown }) => {
    const pending = pendingTopology.get(requestId); if (!pending) return;
    pendingTopology.delete(requestId); clearTimeout(pending.timer);
    if ("error" in outcome) pending.reject(errorOf(outcome.error)); else pending.resolve(outcome.value);
  };
  const fail = (childId: string, error: unknown) => supervisor.send({ type: "CHILD.FAILED", childId, reason: errorOf(error).message, abnormal: true });
  const ipcLogic = fromCallback(() => {
    let childStopped = false; const started = ipcCleanup.then(() => effects.startIpc());
    void started.catch((error) => { if (!childStopped) fail("renderer-ipc", error); });
    return () => {
      childStopped = true;
      ipcCleanup = started.catch(() => undefined).then(() => effects.stopIpc()).catch((error) => { ipcStopFailures.push(errorOf(error)); });
    };
  });
  const reconciliationLogic = fromCallback<ProductionEffectEvent>(({ receive }) => {
    let childStopped = false; let pending = Promise.resolve<unknown>(undefined);
    const enqueueReconciliation = () => {
      const result = pending.then(() => effects.reconcile());
      pending = result.catch((error) => { if (!childStopped) fail("topology-reconciliation", error); });
    };
    receive((event) => {
      if (event.type !== "TOPOLOGY.EXECUTE" || childStopped) return;
      const result = pending.then(() => {
        if (!pendingTopology.has(event.requestId)) throw new Error(`topology request ${event.requestId} expired before execution`);
        return event.operation();
      });
      pending = result.catch(() => undefined);
      void result.then(
        (value) => settleTopology(event.requestId, { value }),
        (error) => settleTopology(event.requestId, { error }),
      );
    });
    enqueueReconciliation(); const interval = setInterval(enqueueReconciliation, effects.intervalMs); interval.unref?.();
    return () => { childStopped = true; clearInterval(interval); rejectTopologyPending(new Error("topology child exited before pending requests settled")); };
  }) as AnyActorLogic;
  const projectionLogic = fromCallback<ProductionEffectEvent>(({ receive }) => {
    let childStopped = false; let pending = Promise.resolve();
    receive((event) => {
      if (event.type !== "PROJECTION.PUBLISH" || childStopped) return;
      pending = pending.then(() => effects.publishProjection(event.projection)).catch((error) => fail("projection-publication", error));
    });
    return () => { childStopped = true; };
  }) as AnyActorLogic;
  const recordReceipt = (receipt: FailureReceipt) => {
    if (receipt.childId === "topology-reconciliation") rejectTopologyPending(new Error(`topology child ${receipt.decision}: ${receipt.reason}`));
    effects.receipt?.(receipt);
  };
  supervisor = createSupervisorActor({
    id: "production-effects-supervisor",
    strategy: "one_for_one",
    children: [
      { id: "renderer-ipc", logic: ipcLogic, restart: "permanent" },
      { id: "topology-reconciliation", logic: reconciliationLogic, restart: "permanent" },
      { id: "projection-publication", logic: projectionLogic, restart: "permanent" },
    ],
    receipt: recordReceipt,
    escalate: effects.escalate,
  });
  return {
    start() { stopped = false; supervisor.start(); supervisor.send({ type: "SUPERVISOR.START" }); },
    send(event: ProductionEffectEvent | SupervisorEvent): ChildDelivery | void {
      if (event.type === "PROJECTION.PUBLISH") return supervisor.sendChild("projection-publication", event);
      if (event.type === "TOPOLOGY.EXECUTE") return supervisor.sendChild("topology-reconciliation", event);
      supervisor.send(event);
    },
    executeTopology<T>(operation: () => Promise<T>): Promise<T> {
      if (stopped) return Promise.reject(new Error("production supervisor is stopped"));
      const requestId = `topology:${randomUUID()}`;
      return new Promise<T>((resolve, reject) => {
        const timer = setTimeout(() => {
          pendingTopology.delete(requestId);
          reject(new Error(`topology request timed out after ${topologyTimeoutMs}ms`));
        }, topologyTimeoutMs);
        timer.unref?.();
        pendingTopology.set(requestId, { resolve: (value) => resolve(value as T), reject, timer });
        const delivery = supervisor.sendChild("topology-reconciliation", { type: "TOPOLOGY.EXECUTE", requestId, operation });
        if (!delivery.delivered) {
          pendingTopology.delete(requestId); clearTimeout(timer);
          reject(new Error(delivery.reason));
        }
      });
    },
    addRenderer(spec: RendererLifecycleSpec): ChildDelivery {
      if (stopped || !supervisor.getSnapshot().matches("running")) return { delivered: false, childId: spec.childId, state: "supervisor-stopped", reason: "production supervisor is stopped" };
      if (supervisor.childState(spec.childId) !== "missing") return { delivered: false, childId: spec.childId, state: supervisor.childState(spec.childId), reason: `renderer child ${spec.childId} already exists` } as ChildDelivery;
      const logic = fromPromise(async ({ signal }) => spec.run(signal));
      supervisor.send({ type: "CHILD.ADD", spec: { id: spec.childId, logic, restart: spec.restart } });
      return supervisor.childState(spec.childId) === "running"
        ? { delivered: true, childId: spec.childId, state: "running" }
        : { delivered: false, childId: spec.childId, state: supervisor.childState(spec.childId), reason: `renderer child ${spec.childId} did not start` } as ChildDelivery;
    },
    removeRenderer(childId: string): void { supervisor.send({ type: "CHILD.REMOVE", childId }); },
    rendererState(childId: string) { return supervisor.childState(childId); },
    childState(childId: string) { return supervisor.childState(childId); },
    async stop(): Promise<void> {
      stopped = true; rejectTopologyPending(new Error("production supervisor stopped"));
      supervisor.send({ type: "SUPERVISOR.STOP" }); supervisor.stop(); await ipcCleanup;
      if (ipcStopFailures.length) throw new AggregateError(ipcStopFailures.splice(0), "production IPC cleanup failed");
    },
    getSnapshot: () => supervisor.getSnapshot(),
  };
}
