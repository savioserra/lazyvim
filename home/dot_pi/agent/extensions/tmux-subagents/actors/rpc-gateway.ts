import { fromCallback, fromPromise } from "xstate";
import type { Projection } from "../domain/projection.ts";
import type { ActorEvent } from "../protocol/actor-events.ts";
import type { SubagentsRpcClient } from "../adapters/pi-subagents-rpc.ts";
import { executeControlRequest, type ControlOutput } from "../actions/controls.ts";

export const rpcGatewayLogic = fromCallback<ActorEvent>(({ receive }) => { receive(() => { /* root owns correlation; gateway lifecycle is supervised here */ }); });

export const refreshAuthorityLogic = fromPromise<Projection, { rpc: SubagentsRpcClient }>(({ input }) => input.rpc.status());
export const controlAuthorityLogic = fromPromise<ControlOutput, { rpc: SubagentsRpcClient; request: Extract<ActorEvent, { type: "CONTROL.REQUEST" }> }>(({ input }) => executeControlRequest(input.rpc, input.request));
