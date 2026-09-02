import { boundedAssistantAnswer, deliveryKindLabel } from "../hosted-pi-bridge/handlers.ts";
import { safePreview, type CommunicationView } from "../hosted-pi-bridge/communication-ui.ts";
import { incomingCard } from "./projections/conversation.ts";
import { conversationEnvelope, type ActorClientRenderEnvelope } from "./projections/render-envelope.ts";
import type { ConversationCard } from "./projections/types.ts";

const MAX_TEXT = 16 * 1024;
export const REGULAR_DELIVERY_MARKER = "actor-client-regular-delivery-marker";
export const REGULAR_DELIVERY_MESSAGE = "actor-client-regular-delivery";

export type RegularDelivery = {
  sequence: bigint;
  source?: { stableId?: string; displayName?: string; role?: string };
  targetAgentId?: string;
  requestId?: string;
  dedupeId: string;
  chainId?: string;
  deadlineUnixMillis: bigint;
  hopLimit: number;
  boundedPayload: Uint8Array;
  kind: number;
  sourceScope?: string;
  completionKey?: string;
};
export type RegularFence = { handle: string; fence: bigint };
export type RegularDeliveryMarker = { key: string; stage: "injected" | "acked"; kind: number };
export type RegularDeliveryMessage = { key: string; renderEnvelope: ActorClientRenderEnvelope; view?: CommunicationView };

type Pending = { delivery: RegularDelivery; fence: RegularFence; outcome?: { delivered: boolean; answer: string; reason: string }; lastRunMessages: unknown[]; timer?: NodeJS.Timeout };
type Dependencies = {
  appendMarker(marker: RegularDeliveryMarker): void;
  sendFollowUp(message: RegularDeliveryMessage, text: string): void;
  acknowledge(delivery: RegularDelivery, fence: RegularFence, delivered: boolean, answer: string, reason: string): Promise<void>;
  projectIncoming?(delivery: RegularDelivery, prompt: boolean, card: ConversationCard): RegularDeliveryMessage;
  now?: () => number;
};

export function regularDeliveryKey(delivery: Pick<RegularDelivery, "completionKey" | "dedupeId" | "sequence">): string {
  return delivery.completionKey || `${delivery.dedupeId}\0${delivery.sequence}`;
}

const ACK_BUSY_RETRIES = 5;
const ACK_BUSY_DELAY_MS = 25;

async function acknowledgeAfterPersistence(fence: RegularFence, attempt: (fence: RegularFence) => Promise<void>): Promise<void> {
  for (let retry = 0; ; retry++) {
    try { await attempt(fence); return; }
    catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message !== "durable persistence is busy" || retry >= ACK_BUSY_RETRIES) throw error;
      await new Promise((resolve) => setTimeout(resolve, ACK_BUSY_DELAY_MS * (retry + 1)));
    }
  }
}

export async function acknowledgeWithFenceRefresh(fence: RegularFence, attempt: (fence: RegularFence) => Promise<void>, refresh: () => Promise<RegularFence>): Promise<void> {
  try { await acknowledgeAfterPersistence(fence, attempt); return; }
  catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!/fence rejected|authorization denied/.test(message)) throw error;
  }
  // Reattach itself is a durable mutation. Retry only its exact transient-busy
  // successor so a fresh fence cannot enter an endless replay/reject loop.
  await acknowledgeAfterPersistence(await refresh(), attempt);
}

function peerFromDelivery(peer: RegularDelivery["source"]) {
  if (!peer?.displayName) return undefined;
  return { stableId: peer.stableId, displayName: peer.displayName, role: peer.role, authoritative: true };
}

export class RegularDeliveryCoordinator {
  private readonly injected = new Set<string>();
  private readonly acked = new Set<string>();
  private pending?: Pending;
  private tail = Promise.resolve();
  private readonly dependencies: Dependencies;
  constructor(dependencies: Dependencies) { this.dependencies = dependencies; }

  restore(entries: readonly any[]) {
    for (const entry of entries) {
      if (entry?.type !== "custom" || entry.customType !== REGULAR_DELIVERY_MARKER) continue;
      const marker = entry.data as Partial<RegularDeliveryMarker> | undefined;
      if (!marker?.key) continue;
      this.injected.add(marker.key);
      if (marker.stage === "acked") this.acked.add(marker.key);
    }
  }

  deliver(delivery: RegularDelivery, fence: RegularFence): Promise<void> {
    const operation = this.tail.then(() => this.deliverNow(delivery, fence));
    this.tail = operation.catch(() => {});
    return operation;
  }

  agentEnd(messages: unknown[]) { if (this.pending && !this.pending.outcome) this.pending.lastRunMessages = messages ?? []; }
  async settled() {
    const pending = this.pending;
    if (!pending) return;
    if (pending.outcome) {
      await this.finish(pending, pending.outcome.delivered, pending.outcome.answer, pending.outcome.reason);
      return;
    }
    const answer = boundedAssistantAnswer(pending.lastRunMessages);
    await this.finish(pending, Boolean(answer), answer, answer ? "" : "prompt run ended without an assistant answer");
  }
  async shutdown() { if (this.pending) await this.finish(this.pending, false, "", "terminal Pi session shut down before prompt completion"); }

  private async deliverNow(delivery: RegularDelivery, fence: RegularFence) {
    this.validate(delivery);
    const key = regularDeliveryKey(delivery);
    if (this.acked.has(key)) return;
    if (BigInt(this.now()) > delivery.deadlineUnixMillis) {
      await this.finish({ delivery, fence, lastRunMessages: [] }, false, "", "regular delivery deadline expired before injection");
      return;
    }
    if (delivery.kind === 4) {
      if (this.pending && regularDeliveryKey(this.pending.delivery) !== key) throw new Error("a different regular prompt delivery is already active");
      if (!this.pending) this.pending = { delivery, fence, lastRunMessages: [] };
      if (this.pending.outcome) {
        await this.finish(this.pending, this.pending.outcome.delivered, this.pending.outcome.answer, this.pending.outcome.reason);
        return;
      }
      if (!this.injected.has(key)) await this.inject(this.pending, true);
      this.armDeadline(this.pending);
      return;
    }
    if (delivery.kind !== 1) throw new Error("regular actor-client accepts only notification or prompt deliveries");
    const pending: Pending = { delivery, fence, lastRunMessages: [] };
    if (!this.injected.has(key)) await this.inject(pending, false);
    await this.finish(pending, true, "", "delivered to terminal");
  }

  private async inject(pending: Pending, prompt: boolean) {
    const key = regularDeliveryKey(pending.delivery);
    const text = new TextDecoder("utf-8", { fatal: true }).decode(pending.delivery.boundedPayload).trim();
    if (!text) throw new Error("regular delivery payload is empty");
    // Persist the dedupe marker before the model-visible follow-up. A replay can
    // therefore re-ACK, but can never inject the same work twice.
    this.dependencies.appendMarker({ key, stage: "injected", kind: pending.delivery.kind });
    this.injected.add(key);
    const card = incomingCard({ key, source: peerFromDelivery(pending.delivery.source), body: pending.delivery.boundedPayload, request: prompt });
    const message = this.dependencies.projectIncoming?.(pending.delivery, prompt, card) ?? { key, renderEnvelope: conversationEnvelope(card) };
    try {
      // Pi's sendMessage contract synchronously enqueues the follow-up. Do not
      // await an implementation thenable here: it may span the triggered model
      // turn and head-of-line block later durable deliveries and Tell ACKs.
      this.dependencies.sendFollowUp(message, text);
    } catch (error) {
      await this.finish(pending, false, "", safePreview(error instanceof Error ? error.message : "terminal follow-up injection failed", 200));
    }
  }

  private async finish(pending: Pending, delivered: boolean, answer: string, reason: string) {
    const key = regularDeliveryKey(pending.delivery);
    if (this.acked.has(key)) { if (this.pending === pending) this.clearPending(); return; }
    const encoded = new TextEncoder().encode(answer);
    if (encoded.byteLength > MAX_TEXT) throw new Error("assistant answer exceeds regular delivery bound");
    pending.outcome = { delivered, answer, reason };
    await this.dependencies.acknowledge(pending.delivery, pending.fence, delivered, answer, reason);
    this.dependencies.appendMarker({ key, stage: "acked", kind: pending.delivery.kind });
    this.acked.add(key);
    if (this.pending === pending) this.clearPending();
  }

  private armDeadline(pending: Pending) {
    if (pending.timer) return;
    const delay = Math.max(1, Math.min(Number(pending.delivery.deadlineUnixMillis - BigInt(this.now())), 2_147_483_647));
    pending.timer = setTimeout(() => { void this.finish(pending, false, "", "prompt deadline expired before completion").catch(() => {}); }, delay);
    pending.timer.unref?.();
  }
  private clearPending() { if (this.pending?.timer) clearTimeout(this.pending.timer); this.pending = undefined; }
  private now() { return this.dependencies.now?.() ?? Date.now(); }
  private validate(delivery: RegularDelivery) {
    if (!delivery.dedupeId || !delivery.sourceScope || !delivery.completionKey || delivery.sequence <= 0n || delivery.hopLimit < 1) throw new Error("regular delivery acknowledgement identity is incomplete");
    deliveryKindLabel(delivery.kind);
    if (!delivery.boundedPayload.byteLength || delivery.boundedPayload.byteLength > MAX_TEXT) throw new Error("regular delivery payload exceeds bound");
  }
}
