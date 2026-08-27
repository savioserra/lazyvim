import assert from "node:assert/strict";
import test from "node:test";
import { handleRendererEvent, publicPaneClaimMessage, type ActiveSystem } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/actors/system.ts";
import type { ViewBinding } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/store.ts";
import type { Projection } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/domain/projection.ts";

test("public pane claim message hides raw tmux and run internals", () => {
  const projection: Projection = { schemaVersion: 1, generatedAt: 1, source: "pi-subagents-rpc", omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false }, runs: [{ id: "run-secret-123", kind: "workflow", label: "Release Review", role: "coordination", accessMode: "writer", state: "running", children: [{ id: "child-secret-456", kind: "step", label: "QA Checks", role: "quality assurance", accessMode: "read-only", state: "paused" }] }] };
  const message = publicPaneClaimMessage({ latestProjection: projection } as ActiveSystem, { runId: "run-secret-123", childId: "child-secret-456", created: true });
  assert.match(message, /owned pane/);
  assert.match(message, /QA Checks/);
  assert.match(message, /quality assurance/);
  assert.match(message, /read-only/);
  assert.match(message, /paused/);
  for (const forbidden of ["run-secret-123", "child-secret-456", "%", "/dev/pts", "paneId", "socket", "pid", "prompt", "payload"]) assert.doesNotMatch(message, new RegExp(forbidden, "i"));
});

test("production detach tracks completion and observes durable outcome persistence failure", async () => {
  const binding: ViewBinding = { schemaVersion: 1, bindingId: "binding", generation: "generation", ownerPiSessionId: "session", runId: "run", created: false, projectionPath: "/private/projection", pane: { socketPath: "/tmp/tmux", paneId: "%1", panePid: 1, paneTty: "/dev/pts/1", sessionId: "$1" }, createdAt: 1 };
  const calls: string[] = []; const pendingOperations = new Set<Promise<void>>(); const operationFailures: Error[] = [];
  const state = {
    bindings: new Map([[binding.bindingId, binding]]), tickets: new Map(), rendererConnections: new Map(), closingBindings: new Set(), requestConnections: new Map(), pendingOperations, operationFailures,
    rootActor: { send: (event: { type: string }) => { calls.push(event.type); } }, effectSupervisor: { removeRenderer: () => { calls.push("renderer-remove"); } },
    store: { closeProjection: async () => { calls.push("projection-close"); }, removeBinding: async () => { calls.push("binding-remove"); } },
    ipc: { bindingFor: () => binding.bindingId, revoke: () => { calls.push("ipc-revoke"); }, send: () => {} },
    diagnostics: { record: async (event: { status: string }) => { calls.push(`diagnostic-${event.status}`); throw new Error(`detach ${event.status} persistence failed`); } },
  } as unknown as ActiveSystem;
  handleRendererEvent(state, { type: "RENDER.INPUT", connectionId: "connection", intent: { kind: "detach" } });
  assert.equal(pendingOperations.size, 1, "detach was not retained as an awaited lifecycle operation"); await Promise.allSettled([...pendingOperations]); await new Promise((resolve) => setImmediate(resolve));
  for (const call of ["renderer-remove", "projection-close", "binding-remove", "ipc-revoke", "diagnostic-success", "diagnostic-failure"]) assert.ok(calls.includes(call), `detach skipped ${call}`);
  assert.equal(operationFailures.length, 1); assert.match(operationFailures[0].message, /detach and durable outcome persistence failed/);
});
