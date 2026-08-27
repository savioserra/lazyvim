import { assign, createActor, sendTo, setup, spawnChild, stopChild } from "xstate";
import type { SubagentsRpcClient } from "../adapters/pi-subagents-rpc.ts";
import type { ControlOutput } from "../actions/controls.ts";
import type { Projection } from "../domain/projection.ts";
import { isRefreshRequest } from "../guards/controls.ts";
import { stableSystemId, type ActorEvent } from "../protocol/actor-events.ts";
import { controlAuthorityLogic, refreshAuthorityLogic } from "./rpc-gateway.ts";
import { runMirrorSupervisorLogic } from "./supervisors/run-mirror.ts";

export interface RootInput {
  sessionId: string; generation: string; rpc: SubagentsRpcClient;
  onProjection: (projection: Projection) => void;
  onControlResult?: (event: Extract<ActorEvent, { type: "CONTROL.RESULT" }>) => void;
  onSupervisorReceipt?: (event: Extract<ActorEvent, { type: "SUPERVISOR.RECEIPT" }>) => void;
}
interface RootContext extends RootInput { projection?: Projection; pendingControl?: Extract<ActorEvent, { type: "CONTROL.REQUEST" }>; supervisorHealth: Record<string, string>; onControlResult: NonNullable<RootInput["onControlResult"]>; onSupervisorReceipt: NonNullable<RootInput["onSupervisorReceipt"]> }
type RootEvent = ActorEvent |
  { type: "xstate.done.actor.refresh"; output: Projection } | { type: "xstate.error.actor.refresh"; error: unknown } |
  { type: "xstate.done.actor.control"; output: ControlOutput } | { type: "xstate.error.actor.control"; error: unknown };

export const rootSupervisorMachine = setup({
  types: {} as { context: RootContext; input: RootInput; events: RootEvent },
  actors: { runMirrorSupervisor: runMirrorSupervisorLogic, refresh: refreshAuthorityLogic, control: controlAuthorityLogic },
  guards: { isRefreshRequest: ({ event }) => isRefreshRequest(event as ActorEvent) },
  actions: {
    publishProjection: assign(({ context, event }) => {
      const projection = event.type === "xstate.done.actor.refresh" ? event.output : event.type === "AUTHORITY.SNAPSHOT" ? event.snapshot as Projection : undefined;
      if (!projection) return context; context.onProjection(projection); return { ...context, projection };
    }),
    queueControl: assign({ pendingControl: ({ event }) => event.type === "CONTROL.REQUEST" ? event : undefined }),
    reportControl: ({ context, event }) => { if (event.type === "CONTROL.RESULT") context.onControlResult(event); },
    reportControlDone: ({ context, event }) => { if (event.type === "xstate.done.actor.control") context.onControlResult({ type: "CONTROL.RESULT", requestId: event.output.requestId, ok: event.output.ok, message: event.output.message }); },
    reportControlError: ({ context, event }) => { if (event.type === "xstate.error.actor.control" && context.pendingControl) context.onControlResult({ type: "CONTROL.RESULT", requestId: context.pendingControl.requestId, ok: false, message: event.error instanceof Error ? event.error.message : String(event.error) }); },
    reportControlBusy: ({ context, event }) => { if (event.type === "CONTROL.REQUEST") context.onControlResult({ type: "CONTROL.RESULT", requestId: event.requestId, ok: false, message: "another control request is still awaiting acknowledgement" }); },
    recordSupervisorReceipt: assign(({ context, event }) => { if (event.type !== "SUPERVISOR.RECEIPT") return {}; context.onSupervisorReceipt(event); return { supervisorHealth: { ...context.supervisorHealth, [event.supervisorId]: `${event.decision}:${event.childId}` } }; }),
  },
}).createMachine({
  id: "root-supervisor", initial: "starting", context: ({ input }) => ({ ...input, supervisorHealth: {}, onControlResult: input.onControlResult ?? (() => {}), onSupervisorReceipt: input.onSupervisorReceipt ?? (() => {}) }),
  entry: spawnChild("runMirrorSupervisor", { id: "run-mirror-supervisor", systemId: "run-mirror-supervisor" }),
  exit: stopChild("run-mirror-supervisor"),
  on: { "SUPERVISOR.RECEIPT": { actions: "recordSupervisorReceipt" } },
  states: {
    starting: { always: "refreshing" },
    refreshing: { invoke: { id: "refresh", src: "refresh", input: ({ context }) => ({ rpc: context.rpc }),
      onDone: { target: "ready", actions: ["publishProjection", sendTo("run-mirror-supervisor", ({ event }) => ({ type: "AUTHORITY.SNAPSHOT", snapshot: event.output }))] },
      onError: { target: "degraded" } } },
    ready: { on: {
      "AUTHORITY.HINT": { target: "refreshing" },
      "AUTHORITY.SNAPSHOT": { actions: ["publishProjection", sendTo("run-mirror-supervisor", ({ event }) => event)] },
      "CHILD.FAILED": { target: "degraded" },
      "CONTROL.REQUEST": [{ guard: "isRefreshRequest", target: "refreshing" }, { target: "controlling", actions: "queueControl" }],
      "CONTROL.RESULT": { actions: "reportControl" },
      "SUPERVISOR.STOP": "stopped",
    } },
    controlling: { invoke: { id: "control", src: "control", input: ({ context }) => ({ rpc: context.rpc, request: context.pendingControl! }), onDone: { target: "refreshing", actions: "reportControlDone" }, onError: { target: "ready", actions: "reportControlError" } }, on: { "CONTROL.REQUEST": { actions: "reportControlBusy" }, "SUPERVISOR.STOP": "stopped" } },
    degraded: { on: { "AUTHORITY.HINT": "refreshing", "CONTROL.REQUEST": { actions: "reportControlBusy" }, "SUPERVISOR.STOP": "stopped" } },
    stopped: { type: "final" },
  },
});

export function createRootActor(input: RootInput) { return createActor(rootSupervisorMachine, { id: stableSystemId("root", input.sessionId, input.generation), input }); }
export { createAgentMirrorActor } from "./agent-mirror.ts";
