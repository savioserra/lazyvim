import type { Projection, ProjectionNode } from "../domain/projection.ts";
import type { AuthorityIdentity } from "../domain/types.ts";

export function flattenProjection(projection: Projection): Array<{ identity: AuthorityIdentity; node: ProjectionNode }> {
  const result: Array<{ identity: AuthorityIdentity; node: ProjectionNode }> = [];
  const visit = (runId: string, node: ProjectionNode, root: boolean) => {
    result.push({ identity: root ? { runId } : { runId, childId: node.id }, node });
    for (const child of node.children ?? []) visit(runId, child, false);
  };
  for (const run of projection.runs) visit(run.id, run, true);
  return result;
}
export function mirrorKey(identity: AuthorityIdentity): string { return `${identity.runId}\0${identity.childId ?? ""}`; }
