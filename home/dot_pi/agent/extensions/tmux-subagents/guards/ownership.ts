import type { PaneIdentity } from "../domain/types.ts";
export function bindingMayClosePane(binding: { created: boolean; pane: PaneIdentity }, pane: PaneIdentity): boolean {
  return binding.created && binding.pane.socketPath === pane.socketPath && binding.pane.paneId === pane.paneId && binding.pane.panePid === pane.panePid && binding.pane.paneTty === pane.paneTty && binding.pane.sessionId === pane.sessionId;
}
