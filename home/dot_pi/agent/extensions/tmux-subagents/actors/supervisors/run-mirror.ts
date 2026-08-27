import { fromCallback } from "xstate";
import { flattenProjection, mirrorKey } from "../../actions/projections.ts";
import type { Projection } from "../../domain/projection.ts";
import { stableSystemId, type ActorEvent } from "../../protocol/actor-events.ts";
import { agentMirrorMachine } from "../agent-mirror.ts";
import { createSupervisorActor } from "./supervisor.ts";

export const runMirrorSupervisorLogic = fromCallback<ActorEvent>(({ receive, sendBack }) => {
  const supervisor = createSupervisorActor({ id: "run-mirror-supervisor", strategy: "one_for_one", children: [],
    receipt: (receipt) => sendBack({ type: "SUPERVISOR.RECEIPT", supervisorId: receipt.supervisorId, childId: receipt.childId, decision: receipt.decision, reason: receipt.reason, at: receipt.occurredAt, restartAttempt: receipt.restartAttempt }),
    escalate: (receipt) => sendBack({ type: "CHILD.FAILED", childId: "run-mirror-supervisor", reason: receipt.reason, abnormal: true, at: receipt.occurredAt }) });
  const visible = new Set<string>(); supervisor.start(); supervisor.send({ type: "SUPERVISOR.START" });
  receive((event) => {
    if (event.type === "AUTHORITY.SNAPSHOT") {
      const next = new Set<string>();
      for (const item of flattenProjection(event.snapshot as Projection)) {
        const key = mirrorKey(item.identity); const childId = stableSystemId("agent", item.identity.runId, item.identity.childId ?? "root"); next.add(key);
        if (!visible.has(key)) supervisor.send({ type: "CHILD.ADD", spec: { id: childId, logic: agentMirrorMachine, input: item, restart: "permanent" } });
        else supervisor.send({ type: "CHILD.SEND", childId, event: { type: "AUTHORITY.SNAPSHOT", snapshot: item.node } });
      }
      for (const key of visible) if (!next.has(key)) { const [runId, childId] = key.split("\0"); supervisor.send({ type: "CHILD.REMOVE", childId: stableSystemId("agent", runId, childId || "root") }); }
      visible.clear(); for (const key of next) visible.add(key);
    } else if (event.type === "SUPERVISOR.STOP") supervisor.send(event);
  });
  return () => { supervisor.send({ type: "SUPERVISOR.STOP" }); supervisor.stop(); };
});
