import type { ActorEvent } from "../protocol/actor-events.ts";
import { requiresConfirmation } from "../guards/controls.ts";

export interface ControlOutput { requestId: string; ok: boolean; message: string }
export interface ControlRpcPort {
  control(method: "steer" | "interrupt" | "stop" | "resume", identity: { runId: string; childId?: string }, message?: string): Promise<{ message: string; data: unknown }>;
}
export async function executeControlRequest(rpc: ControlRpcPort, request: Extract<ActorEvent, { type: "CONTROL.REQUEST" }>): Promise<ControlOutput> {
  if (request.operation === "status") return { requestId: request.requestId, ok: true, message: "refresh acknowledged" };
  if (requiresConfirmation(request.operation) && request.confirmed !== true) throw new Error(`${request.operation} requires confirmation`);
  const result = await rpc.control(request.operation, request.identity, request.text);
  return { requestId: request.requestId, ok: true, message: result.message };
}
