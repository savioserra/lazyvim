import { fromCallback, type AnyActorLogic } from "xstate";
import type { DiagnosticJournal } from "../adapters/diagnostic-journal.ts";
import type { DiagnosticActorEvent, DiagnosticEvent, DiagnosticRecord } from "../protocol/diagnostic-events.ts";
import { createSupervisorActor, type FailureReceipt } from "./supervisors/supervisor.ts";

export interface DiagnosticsHealth { state: "healthy" | "degraded" | "circuit-open" | "stopped"; latestErrorReceipt?: string; lastJournalError?: string }

export function createDiagnosticsActor(journal: DiagnosticJournal, onSupervisorReceipt?: (receipt: FailureReceipt) => void) {
  let supervisor: ReturnType<typeof createSupervisorActor>;
  let health: DiagnosticsHealth = { state: "stopped" };
  const logic = fromCallback<DiagnosticActorEvent>(({ receive }) => {
    let stopped = false; let pending = Promise.resolve();
    receive((event) => {
      if (stopped) { event.acknowledge?.(new Error("diagnostics observer is stopped")); return; }
      if (event.type === "DIAGNOSTIC.CRASH") {
        const error = new Error("diagnostics observer crash requested"); event.acknowledge?.(error); supervisor.send({ type: "CHILD.FAILED", childId: "diagnostic-journal", reason: error.message, abnormal: true }); return;
      }
      pending = pending.then(async () => {
        if (event.type === "DIAGNOSTIC.QUERY") { event.acknowledge(undefined, await journal.recent(event.count)); return; }
        const record = await journal.append(event as DiagnosticEvent); health = { ...health, state: "healthy", lastJournalError: undefined }; event.acknowledge?.(undefined, record);
      }).catch((error) => {
        const failure = error instanceof Error ? error : new Error(String(error)); health = { ...health, state: "degraded", lastJournalError: failure.message }; event.acknowledge?.(failure);
        supervisor.send({ type: "CHILD.FAILED", childId: "diagnostic-journal", reason: failure.message, abnormal: true });
      });
    });
    return () => { stopped = true; };
  }) as AnyActorLogic;
  supervisor = createSupervisorActor({
    id: "diagnostics-supervisor", strategy: "one_for_one",
    children: [{ id: "diagnostic-journal", logic, restart: "permanent" }],
    receipt: (receipt) => { health = { ...health, state: receipt.decision === "circuit-open" ? "circuit-open" : "degraded" }; onSupervisorReceipt?.(receipt); },
  });
  function deliveryError(): Error {
    const state = supervisor.childState("diagnostic-journal"); return new Error(`diagnostics observer is ${state}`);
  }
  return {
    start(): void { supervisor.start(); supervisor.send({ type: "SUPERVISOR.START" }); health = { state: "healthy" }; },
    async record(event: DiagnosticEvent): Promise<DiagnosticRecord> {
      return new Promise((resolve, reject) => {
        const delivery = supervisor.sendChild("diagnostic-journal", { ...event, acknowledge: (error?: Error, record?: DiagnosticRecord) => error ? reject(error) : record ? resolve(record) : reject(new Error("diagnostics observer returned no record")) });
        if (!delivery.delivered) reject(deliveryError());
      });
    },
    async recent(count = 10): Promise<DiagnosticRecord[]> {
      return new Promise((resolve, reject) => {
        const delivery = supervisor.sendChild("diagnostic-journal", { type: "DIAGNOSTIC.QUERY", count, acknowledge: (error?: Error, records?: DiagnosticRecord[]) => error ? reject(error) : resolve(records ?? []) });
        if (!delivery.delivered) reject(deliveryError());
      });
    },
    crash(): Promise<void> { return new Promise((resolve) => { const delivery = supervisor.sendChild("diagnostic-journal", { type: "DIAGNOSTIC.CRASH", acknowledge: () => resolve() }); if (!delivery.delivered) resolve(); }); },
    health(): DiagnosticsHealth { return { ...health }; },
    setLatestErrorReceipt(receiptId: string): void { health.latestErrorReceipt = receiptId; },
    childState(): string { return supervisor.childState("diagnostic-journal"); },
    async stop(): Promise<void> { health = { ...health, state: "stopped" }; supervisor.send({ type: "SUPERVISOR.STOP" }); supervisor.stop(); await journal.close(); },
  };
}
