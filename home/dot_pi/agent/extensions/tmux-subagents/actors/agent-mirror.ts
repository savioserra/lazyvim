import { assign, createActor, setup } from "xstate";
import type { ProjectionNode } from "../domain/projection.ts";
import type { AuthorityIdentity } from "../domain/types.ts";
import { stableSystemId, type ActorEvent } from "../protocol/actor-events.ts";

export interface AgentMirrorContext { identity: AuthorityIdentity; node: ProjectionNode; revision: number }

export const agentMirrorMachine = setup({
  types: {} as { context: AgentMirrorContext; input: { identity: AuthorityIdentity; node: ProjectionNode }; events: ActorEvent },
}).createMachine({
  id: "agent-mirror", initial: "mirroring",
  context: ({ input }) => ({ identity: input.identity, node: input.node, revision: 0 }),
  states: {
    mirroring: { on: {
      "AUTHORITY.SNAPSHOT": { actions: assign(({ context, event }) => ({ ...context, node: event.snapshot as ProjectionNode, revision: context.revision + 1 })) },
      "RUN.REMOVED": { target: "terminal" },
    } },
    terminal: { type: "final" },
  },
});

export function createAgentMirrorActor(input: { identity: AuthorityIdentity; node: ProjectionNode }) {
  return createActor(agentMirrorMachine, { id: stableSystemId("agent", input.identity.runId, input.identity.childId ?? "root"), input });
}
