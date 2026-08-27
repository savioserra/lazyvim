import type { Projection } from "../domain/projection.ts";
import type { AuthorityIdentity } from "../domain/types.ts";
import { scopeProjection } from "../domain/projection.ts";

export function requireVisibleIdentity(projection: Projection, identity: AuthorityIdentity): void {
  scopeProjection(projection, identity.runId, identity.childId);
}
