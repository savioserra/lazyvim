import type { PendingInteraction } from "./types.ts";

export function restorePending(pending: Map<string, PendingInteraction>, entry: PendingInteraction): Map<string, PendingInteraction> {
  if (pending.has(entry.key)) return pending;
  const next = new Map(pending);
  next.set(entry.key, { ...entry, hidden: true });
  return next;
}

export function clearPending(pending: Map<string, PendingInteraction>, key: string): Map<string, PendingInteraction> {
  if (!pending.has(key)) return pending;
  const next = new Map(pending);
  next.delete(key);
  return next;
}
