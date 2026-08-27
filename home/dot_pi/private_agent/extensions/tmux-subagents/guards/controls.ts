import type { ControlOperation } from "../domain/types.ts";
import type { ActorEvent } from "../protocol/actor-events.ts";
export function requiresConfirmation(operation: ControlOperation): boolean { return operation === "interrupt" || operation === "stop" || operation === "resume"; }
export function isRefreshRequest(event: ActorEvent): event is Extract<ActorEvent, { type: "CONTROL.REQUEST" }> { return event.type === "CONTROL.REQUEST" && event.operation === "status"; }
