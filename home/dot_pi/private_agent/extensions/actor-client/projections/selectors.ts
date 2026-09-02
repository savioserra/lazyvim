import type { ProjectionContext, RenderSnapshot } from "./types.ts";
import { projectSnapshot } from "./layout.ts";

export function selectRenderSnapshot(context: ProjectionContext): RenderSnapshot { return projectSnapshot(context); }
export function selectStatusLine(context: ProjectionContext): string | undefined { return context.snapshot.statusLine; }
export function selectPendingCount(context: ProjectionContext): number { return context.pending.size; }
export function selectPresented(context: ProjectionContext, key: string): boolean { return context.presented.has(key); }
