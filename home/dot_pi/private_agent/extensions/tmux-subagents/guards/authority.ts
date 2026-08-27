import type { AuthorityIdentity } from "../domain/types.ts";
export function identityWithinView(selected: AuthorityIdentity, view: AuthorityIdentity): boolean {
  return selected.runId === view.runId && (!view.childId || selected.childId === view.childId);
}
