import type { ActorUiSnapshot, ProjectionContext, RenderSnapshot } from "./types.ts";
import { projectSnapshot } from "./layout.ts";

export function selectRenderSnapshot(context: ProjectionContext): RenderSnapshot { return projectSnapshot(context); }
export function selectStatusLine(context: ProjectionContext): string | undefined { return context.snapshot.actorStatus.footer; }
export function selectActorUiSnapshot(context: ProjectionContext): ActorUiSnapshot { return context.snapshot.actorStatus; }
export function selectPendingCount(context: ProjectionContext): number { return context.pending.size; }
export function selectPendingStatusLine(context: ProjectionContext): string | undefined {
  const first = context.pending.values().next().value;
  if (!first) return undefined;
  return context.pending.size === 1 ? `◌ Waiting for ${first.target ?? first.targetPeer?.displayName ?? "actor"}…` : `◌ actor asks ${context.pending.size} pending`;
}
export function selectPresented(context: ProjectionContext, key: string): boolean { return context.presented.has(key); }
