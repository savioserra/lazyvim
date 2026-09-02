import { createHash } from "node:crypto";
import { sanitizeText } from "./sanitize.ts";

export function digestPresentation(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value, bigintReplacer)).digest("hex");
}

export function canonicalCompletionKey(input: { completionKey?: string; target?: string; runtimeId?: string; incarnation?: bigint | number | string; deliverySequence?: bigint | number | string; source?: string; requestId?: string; dedupeId?: string; chainId?: string; sourceMutationSequence?: bigint | number | string }): string {
  if (input.completionKey) return sanitizeText(input.completionKey, 256);
  const required = [input.target, input.source, input.requestId, input.dedupeId, input.chainId, input.sourceMutationSequence].every((value) => value !== undefined && String(value) !== "");
  if (!required) throw new Error("completion key identity is incomplete");
  return digestPresentation({ v: 1, target: input.target, runtimeId: input.runtimeId ?? "", incarnation: String(input.incarnation ?? ""), deliverySequence: String(input.deliverySequence ?? ""), source: input.source, requestId: input.requestId, dedupeId: input.dedupeId, chainId: input.chainId, sourceMutationSequence: String(input.sourceMutationSequence) });
}

export function rememberCompletion(completions: Map<string, string>, key: string, digest: string): Map<string, string> {
  const existing = completions.get(key);
  if (existing && existing !== digest) throw new Error("completion key collision");
  if (existing === digest) return completions;
  const next = new Map(completions);
  next.set(key, digest);
  return next;
}

function bigintReplacer(_key: string, value: unknown) { return typeof value === "bigint" ? value.toString() : value; }
