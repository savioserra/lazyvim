import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { create, fromBinary, toBinary, type DescMessage } from "@bufbuild/protobuf";
import { randomUUID } from "node:crypto";
import { readFile, lstat } from "node:fs/promises";
import { Type } from "typebox";
type Envelope = any;
let EnvelopeSchema: DescMessage;
import { buildActorControl, buildActorMessage, communicationKey, CommunicationTimeline, completeHostedEnvironment, drainPages, ExactMutationSequencer, executeTypedDelivery, invokeTypedDeliveryForAck, mutationScopeKey, PromptTaskCoordinator, registerHostedHandlers } from "./handlers.ts";
import { incomingControl, incomingNote, incomingRequestText, legacyCommunicationLine, outgoingExchange, peerView, renderCommunicationCard, type CommunicationView } from "./communication-ui.ts";

const MAX_FRAME = 64 * 1024;
const MAX_TEXT = 16 * 1024;
const REQUEST_TIMEOUT_MS = 30 * 60_000;
const SHORT_REQUEST_TIMEOUT_MS = 2_000;
const ASK_TIMEOUT_MS = REQUEST_TIMEOUT_MS;
const textDecoder = new TextDecoder("utf-8", { fatal: true });

type CredentialFile = { credential_b64: string };
type CommunicationEntry = { key: string; line?: string; view?: CommunicationView };
type DeliveryMarker = { dedupeId: string; sequence: string; kind?: number | string };
type Binding = {
  endpoint: string;
  sessionId: string;
  generationId: string;
  caller: string;
  agentId: string;
  runtimeId: string;
  incarnation: bigint;
  credential: Uint8Array;
};
type TargetFence = { handle: string; fence: bigint };

class FramedClient {
  private socket?: WebSocket;
  private sequence = 0n;
  private pendingWrite = Promise.resolve();
  private buffer = Buffer.alloc(0);
  private readonly pendingResponses = new Map<string, { sequence: bigint; resolve(value: Envelope): void; reject(error: Error): void; timer: NodeJS.Timeout }>();

  private readonly binding: Binding;
  private readonly onPush?: (frame: Envelope) => void | Promise<void>;

  constructor(binding: Binding, onPush?: (frame: Envelope) => void | Promise<void>) {
    this.binding = binding;
    this.onPush = onPush;
  }

  async open(): Promise<void> {
    validateActorEndpoint(this.binding.endpoint);
    this.socket = await new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(this.binding.endpoint);
      socket.binaryType = "arraybuffer";
      const timer = setTimeout(() => { socket.close(); reject(new Error("daemon websocket deadline expired")); }, SHORT_REQUEST_TIMEOUT_MS);
      socket.addEventListener("open", () => { clearTimeout(timer); resolve(socket); }, { once: true });
      socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("daemon websocket error")); }, { once: true });
    });
    this.socket.addEventListener("message", (event) => { void this.onMessage(event); });
    this.socket.addEventListener("close", () => this.rejectAll(new Error("daemon connection closed")), { once: true });
    this.socket.addEventListener("error", () => this.rejectAll(new Error("daemon websocket error")), { once: true });
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = undefined;
    if (!socket) return;
    socket.close();
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, 250);
      socket.addEventListener("close", () => { clearTimeout(timer); resolve(); }, { once: true });
    });
  }

  request<T>(payloadCase: string, schema: DescMessage, value: T, target?: TargetFence, requestId?: string, timeoutMillis = REQUEST_TIMEOUT_MS): Promise<Envelope> {
    const operation = this.pendingWrite.then(() => this.requestNow(payloadCase, schema, value, target, requestId, timeoutMillis));
    this.pendingWrite = operation.then(() => undefined, () => undefined);
    return operation;
  }

  isOpen(): boolean { return this.socket !== undefined; }
  invalidate(error: Error): void { const socket=this.socket;this.socket=undefined;this.rejectAll(error);socket?.close(); }

  private requestNow<T>(payloadCase: string, schema: DescMessage, value: T, target?: TargetFence, requestId?: string, timeoutMillis = REQUEST_TIMEOUT_MS): Promise<Envelope> {
    const socket = this.socket;
    if (!socket) throw new Error("hosted bridge is disconnected");
    this.sequence++;
    const envelope = create(EnvelopeSchema, {
      protocolMajor: 1,
      protocolMinor: 1,
      sessionId: this.binding.sessionId,
      generationId: this.binding.generationId,
      requestId: requestId ?? randomUUID(),
      deadlineUnixMillis: BigInt(Date.now() + timeoutMillis),
      sequence: this.sequence,
      callerIdentity: this.binding.caller,
      agentHandle: target?.handle ?? "",
      sessionCredential: this.binding.credential,
      agentFence: target?.fence ?? 0n,
      payload: { case: payloadCase as never, value: create(schema, value as never) as never },
    });
    const bytes = toBinary(EnvelopeSchema, envelope);
    if (bytes.byteLength > MAX_FRAME) throw new Error("hosted bridge request exceeds frame bound");
    const frame = new Uint8Array(bytes.byteLength + 4);
    new DataView(frame.buffer).setUint32(0, bytes.byteLength, false);
    frame.set(bytes, 4);
    return new Promise<Envelope>((resolve, reject) => {
      const timer = setTimeout(() => { this.pendingResponses.delete(envelope.requestId); reject(new Error("daemon response deadline expired")); this.invalidate(new Error("daemon response deadline expired")); }, timeoutMillis);
      this.pendingResponses.set(envelope.requestId, { sequence: envelope.sequence, resolve, reject, timer });
      socket.send(frame);
    });
  }

  private async onMessage(event: MessageEvent): Promise<void> {
    const chunk = event.data instanceof ArrayBuffer ? Buffer.from(event.data) : event.data instanceof Blob ? Buffer.from(await event.data.arrayBuffer()) : Buffer.isBuffer(event.data) ? event.data : undefined;
    if (!chunk) { this.rejectAll(new Error("daemon websocket payload is not binary")); return; }
    this.onData(chunk);
  }

  private onData(chunk: Buffer) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.byteLength < 4) return;
      const length = this.buffer.readUInt32BE(0);
      if (length === 0 || length > MAX_FRAME) { this.invalidate(new Error("daemon frame bound violated")); return; }
      if (this.buffer.byteLength < length + 4) return;
      const bytes = this.buffer.subarray(4, length + 4);
      this.buffer = this.buffer.subarray(length + 4);
      try { this.demux(fromBinary(EnvelopeSchema, bytes)); }
      catch (error) { this.invalidate(error instanceof Error ? error : new Error("daemon frame decode failed")); return; }
    }
  }

  private demux(envelope: Envelope) {
    if (envelope.payload.case === "bridgePushFrame") { void this.onPush?.(envelope); return; }
    const pending = this.pendingResponses.get(envelope.requestId);
    if (!pending || pending.sequence !== envelope.sequence) { this.invalidate(new Error("hosted bridge response correlation mismatch")); return; }
    this.pendingResponses.delete(envelope.requestId);
    clearTimeout(pending.timer);
    if (envelope.payload.case === "protocolError") pending.reject(new Error(envelope.payload.value.message || "daemon rejected hosted bridge request"));
    else pending.resolve(envelope);
  }

  private rejectAll(error: Error) {
    for (const [id, pending] of this.pendingResponses) { clearTimeout(pending.timer); pending.reject(error); this.pendingResponses.delete(id); }
  }
}

export default async function hostedPiBridge(pi: ExtensionAPI) {
  // Global discovery is inert unless the complete hosted-owned environment is
  // present and structurally valid. Ownership is revalidated during startup.
  if (!completeHostedEnvironment(process.env)) return;
  const proto = await import("./subagents_pb.ts");
  const { ActorControlRequestSchema, ActorControlRequest_Intent, ActorMessageRequestSchema, ActorMessageRequest_Mode, AttachRequestSchema, BridgeConnectRequestSchema, BridgeDeliveryAckRequestSchema, BridgeHeartbeatRequestSchema, BridgeLifecycleRequestSchema, BridgeLifecycleRequest_Event, BridgePollRequestSchema, DetachAgentRequestSchema, ListAgentsRequestSchema, ResolveAgentRequestSchema, SubscribeAgentRequestSchema, UnsubscribeAgentRequestSchema } = proto;
  EnvelopeSchema = proto.EnvelopeSchema;

  let client: FramedClient | undefined;
  let pollClient: FramedClient | undefined;
  let binding: Binding | undefined;
  let selfFence: TargetFence | undefined;
  const fences = new Map<string, TargetFence>();
  const subscriptions = new Set<string>();
  const delivered = new Set<string>();
  let piSessionId = "";
  let reconnecting: Promise<void> | undefined;
  let heartbeatTimer: NodeJS.Timeout | undefined;
  let lastAckedSequence = 0n;
  const pendingPushFrames: Envelope[] = [];
  let pushTail = Promise.resolve();
  const pollSequences = new Map<string, bigint>();
  const mutations = new ExactMutationSequencer();
  const timeline = new CommunicationTimeline(512);
  let extensionContext: ExtensionContext | undefined;

  pi.registerEntryRenderer<CommunicationEntry>("hosted-pi-communication", (entry, _options, theme) => {
    if (entry.data?.view) return renderCommunicationCard(entry.data.view, theme);
    const line = boundedPublic(entry.data?.line ?? "Communication event unavailable", 160);
    return new Text(`${theme.fg("accent", "Communication")}  ${line}`, 0, 0);
  });
  const prompts = new PromptTaskCoordinator<TargetFence>((text) => { requiredContext(extensionContext); pi.sendUserMessage(text); }, async (pending, deliveredSuccessfully, answer, reason) => {
    const encoded = new TextEncoder().encode(answer);
    if (encoded.byteLength > MAX_TEXT) throw new Error("assistant answer exceeds bridge bound");
    const ack = { agentId: requiredBinding(binding).agentId, sequence: pending.delivery.sequence, dedupeId: pending.delivery.dedupeId, delivered: deliveredSuccessfully, reason, boundedResult: encoded };
    const response = await requiredClient(client).request("bridgeDeliveryAckRequest", BridgeDeliveryAckRequestSchema, ack, pending.fence);
    if (response.payload.case !== "bridgeDeliveryAckResponse" || !response.payload.value.accepted) throw new Error("prompt completion acknowledgement rejected");
    if (deliveredSuccessfully) deliveredPrompt(pending.delivery.dedupeId, pending.delivery.sequence);
  });

  const list = async () => {
    const response = await requiredClient(client).request("listAgentsRequest", ListAgentsRequestSchema, {});
    if (response.payload.case !== "listAgentsResponse") throw new Error("unexpected list response");
    return response.payload.value.agents.map((agent) => ({ id: agent.agentId, role: agent.role, displayName: agent.displayName, revision: agent.lifecycleRevision.toString(), runtimeState: agent.hostedPiRuntime?.state ?? 0 }));
  };

  const resolve = async (target?: string) => {
    const value = target?.trim() || requiredBinding(binding).agentId;
    const response = await requiredClient(client).request("resolveAgentRequest", ResolveAgentRequestSchema, { agentId: value });
    if (response.payload.case !== "resolveAgentResponse") throw new Error("unexpected resolve response");
    return {
      agent: response.payload.value.agent?.agentId,
      role: response.payload.value.agent?.role,
      displayName: response.payload.value.agent?.displayName,
      ambiguous: response.payload.value.ambiguous,
      candidates: response.payload.value.candidates.map((candidate) => ({ id: candidate.agentId, role: candidate.role, displayName: candidate.displayName })),
    };
  };

  const ensureFence = async (target: string): Promise<TargetFence> => {
    const existing = fences.get(target);
    if (existing) return existing;
    const response = await requiredClient(client).request("attachRequest", AttachRequestSchema, { agentId: target, requestedCapabilities: ["observe", "send", "ask", "control_abort", "control_shutdown"] });
    if (response.payload.case !== "attachResponse" || !response.payload.value.agentHandle) throw new Error("target attach rejected");
    const fence = { handle: response.payload.value.agentHandle, fence: response.payload.value.fence };
    fences.set(target, fence);
    return fence;
  };

  const message = async (mode: ActorMessageRequest_Mode, target: string | undefined, text: string) => {
    const current = requiredBinding(binding); const destination = target?.trim() || current.agentId; const fence = await ensureFence(destination);
    const inherited = prompts.active()?.delivery;
    if (inherited && inherited.hopLimit < 1) throw new Error("inherited prompt hop budget exhausted");
    return mutations.run(mutationScopeKey(fence,current.incarnation),
      (sequence)=>({requestId:randomUUID(),value:buildActorMessage(mode,destination,text,randomUUID(),inherited?.chainId ?? randomUUID(),sequence,inherited?.hopLimit ?? 8)}),
      async (logical)=>{const started=Date.now();const active=requiredClient(client);const response=await active.request("actorMessageRequest",ActorMessageRequestSchema,logical.value,fence,logical.requestId,mode===ActorMessageRequest_Mode.ASK?ASK_TIMEOUT_MS:SHORT_REQUEST_TIMEOUT_MS);if(response.payload.case!=="actorMessageResponse"){active.invalidate(new Error("unexpected actor message response"));throw new Error("unexpected actor message response")};const result=actorMessageModelResult(logical,response.payload.value);appendCommunicationView(outgoingExchange({key:`request:${logical.requestId}`,target:response.payload.value.target,body:text,reply:mode===ActorMessageRequest_Mode.ASK?result.result:undefined,accepted:response.payload.value.accepted,completed:response.payload.value.completed,mode:mode===ActorMessageRequest_Mode.ASK?"ask":"tell",reason:response.payload.value.reason,durationMillis:Date.now()-started}));return result},

      async()=>reconnect(requiredContext(extensionContext)));
  };

  const control = async (intent: ActorControlRequest_Intent, target?: string) => {
    const current=requiredBinding(binding);const destination=target?.trim()||current.agentId;const fence=await ensureFence(destination);
    const inherited = prompts.active()?.delivery;
    if (inherited && inherited.hopLimit < 1) throw new Error("inherited prompt hop budget exhausted");
    return mutations.run(mutationScopeKey(fence,current.incarnation),
      (sequence)=>({requestId:randomUUID(),value:buildActorControl(intent,destination,randomUUID(),inherited?.chainId ?? randomUUID(),sequence,inherited?.hopLimit ?? 2)}),
      async(logical)=>{const active=requiredClient(client);const response=await active.request("actorControlRequest",ActorControlRequestSchema,logical.value,fence,logical.requestId,SHORT_REQUEST_TIMEOUT_MS);if(response.payload.case!=="actorMessageResponse"){active.invalidate(new Error("unexpected actor control response"));throw new Error("unexpected actor control response")};return {accepted:response.payload.value.accepted,reason:response.payload.value.reason}},
      async()=>reconnect(requiredContext(extensionContext)));
  };

  const subscribe = async (target?: string) => {
    const destination = target?.trim() || requiredBinding(binding).agentId;
    const fence = await ensureFence(destination);
    const response = await requiredClient(client).request("subscribeAgentRequest", SubscribeAgentRequestSchema, { agentId: destination, afterRevision: 0n }, fence);
    if (response.payload.case !== "agentOperationResponse") throw new Error("unexpected subscribe response");
    if (response.payload.value.completed) subscriptions.add(destination);
    return { completed: response.payload.value.completed, revision: response.payload.value.revision.toString(), reason: response.payload.value.reason };
  };

  const unsubscribe = async (target?: string) => {
    const destination = target?.trim() || requiredBinding(binding).agentId;
    const fence = await ensureFence(destination);
    const response = await requiredClient(client).request("unsubscribeAgentRequest", UnsubscribeAgentRequestSchema, { agentId: destination }, fence);
    if (response.payload.case !== "agentOperationResponse") throw new Error("unexpected unsubscribe response");
    if (response.payload.value.completed) subscriptions.delete(destination);
    return { completed: response.payload.value.completed, revision: response.payload.value.revision.toString(), reason: response.payload.value.reason };
  };

  const targetSchema = Type.Optional(Type.String({ description: "Stable logical actor ID; omitted means self for human commands" }));
  const modelTargetSchema = Type.Object({ target: Type.String({ minLength: 1, description: "Explicit stable logical actor ID" }) });
  const messageSchema = Type.Object({ target: Type.String({ minLength: 1 }), message: Type.String({ maxLength: MAX_TEXT }) });
  registerHostedHandlers(pi as any, { list, resolve, message: (mode, target, text) => message(mode as ActorMessageRequest_Mode, target, text), control: (intent, target) => control(intent as ActorControlRequest_Intent, target), subscribe, unsubscribe }, { empty: Type.Object({}), target: Type.Object({ target: targetSchema }), modelTarget: modelTargetSchema, message: messageSchema });

  pi.on("session_start", async (_event, ctx) => {
    extensionContext = ctx;
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type !== "custom") continue;
      if (entry.customType === "hosted-pi-delivery-marker") {
        const data = entry.data as Partial<DeliveryMarker> | undefined;
        if (typeof data?.dedupeId === "string") {
          delivered.add(data.dedupeId);
          try { lastAckedSequence = maxBigInt(lastAckedSequence, BigInt(data.sequence ?? "0")); } catch { /* ignore malformed legacy marker */ }
        }
        continue;
      }
      if (entry.customType !== "hosted-pi-communication") continue;
      const data = entry.data as Partial<CommunicationEntry> | undefined;
      if (typeof data?.key !== "string") continue;
      restoreDeliveryMarkerFromKey(data.key);
      if (data.view) timeline.add({ key: data.key, line: legacyCommunicationLine(data.view) });
      else if (typeof data.line === "string") timeline.add({ key: data.key, line: boundedPublic(data.line, 160) });
    }
    binding = await loadBinding();
    client = new FramedClient(binding, (frame) => schedulePush(ctx, frame));
    pollClient = client;
    await client.open();
    piSessionId = ctx.sessionManager.getSessionId();
    if (!piSessionId) throw new Error("hosted Pi session identity is empty");
    const response = await connectBridgeWithRetry(client, binding, piSessionId, lastAckedSequence, BridgeConnectRequestSchema);
    selfFence = { handle: response.payload.value.agentHandle, fence: response.payload.value.fence };
    fences.set(binding.agentId, selfFence);
    for (const frame of pendingPushFrames.splice(0)) schedulePush(ctx, frame);
    await pushTail;
    await lifecycle(BridgeLifecycleRequest_Event.SESSION_START);
    await lifecycle(BridgeLifecycleRequest_Event.READY);
    heartbeatTimer = setInterval(() => { void heartbeat().catch(() => reconnect(ctx)); }, 400);
    heartbeatTimer.unref();
    ctx.ui.setStatus("hosted-pi-bridge", "hosted bridge ready");
  });

  pi.on("agent_start", async () => { await lifecycle(BridgeLifecycleRequest_Event.AGENT_START); });
  pi.on("agent_end", async (event) => { await prompts.agentEnd(event.messages as unknown[]); });
  pi.on("agent_settled", async () => { await lifecycle(BridgeLifecycleRequest_Event.AGENT_SETTLED); });

  pi.on("session_shutdown", async (_event, ctx) => {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = undefined;
    try { await prompts.shutdown(); } catch { /* server timeout remains authoritative */ }
    try { await lifecycle(BridgeLifecycleRequest_Event.SESSION_SHUTDOWN); } catch { /* shutdown remains best effort */ }
    for (const [target, fence] of fences) {
      try {
        const response=await client?.request("detachAgentRequest",DetachAgentRequestSchema,{agentId:target},fence);
        if(response?.payload.case==="agentOperationResponse"&&response.payload.value.completed)mutations.retireScope(mutationScopeKey(fence,requiredBinding(binding).incarnation),true);
      } catch { /* daemon fencing performs final cleanup */ }
    }
    fences.clear();
    subscriptions.clear();
    await client?.close();
    client = undefined;
    pollClient = undefined;
    extensionContext = undefined;
    ctx.ui.setStatus("hosted-pi-bridge", undefined);
  });

  async function heartbeat() {
    const current = requiredBinding(binding);
    const fence = requiredFence(selfFence);
    const response = await requiredClient(client).request("bridgeHeartbeatRequest", BridgeHeartbeatRequestSchema, { agentId: current.agentId, runtimeId: current.runtimeId, incarnation: current.incarnation }, fence, undefined, SHORT_REQUEST_TIMEOUT_MS);
    if (response.payload.case !== "bridgeHeartbeatResponse" || !response.payload.value.accepted) throw new Error("hosted bridge heartbeat rejected");
  }

  async function lifecycle(event: BridgeLifecycleRequest_Event) {
    const current = requiredBinding(binding);
    const fence = requiredFence(selfFence);
    const response = await requiredClient(client).request("bridgeLifecycleRequest", BridgeLifecycleRequestSchema, { agentId: current.agentId, runtimeId: current.runtimeId, incarnation: current.incarnation, event }, fence);
    if (response.payload.case !== "bridgeLifecycleResponse" || !response.payload.value.accepted) throw new Error("hosted bridge lifecycle report rejected");
  }

  function schedulePush(ctx: ExtensionContext, envelope: Envelope) {
    if (!selfFence) {
      if (pendingPushFrames.length >= 64) { requiredClient(client).invalidate(new Error("hosted bridge pre-connect push buffer exhausted")); return; }
      pendingPushFrames.push(envelope);
      return;
    }
    pushTail = pushTail.then(() => handlePush(ctx, envelope)).catch(() => reconnect(ctx));
  }

  async function handlePush(ctx: ExtensionContext, envelope: Envelope) {
    if (envelope.payload.case !== "bridgePushFrame") return;
    const frame = envelope.payload.value;
    for (const event of frame.events) ctx.ui.setStatus("hosted-pi-event", `${boundedPublic(event.agentId)}: ${boundedPublic(event.operation)} @${event.revision}`);
    const current = requiredBinding(binding);
    if (frame.agentId !== current.agentId) return;
    const fence = requiredFence(fences.get(frame.agentId));
    for (const delivery of frame.deliveries) await deliverAndAcknowledge(ctx, delivery, fence);
  }

  async function poll(ctx: ExtensionContext) {
    const current = requiredBinding(binding);
    const targets = new Set([current.agentId, ...subscriptions]);
    for (const target of targets) {
      const fence = requiredFence(fences.get(target));
      const cursor = await drainPages(pollSequences.get(target) ?? 0n,
        async (afterSequence) => {
          const response = await requiredClient(pollClient).request("bridgePollRequest", BridgePollRequestSchema, { afterSequence, maxItems: 64, agentId: target }, fence);
          if (response.payload.case !== "bridgePollResponse") throw new Error("unexpected bridge poll response");
          return response.payload.value;
        },
        async (page) => {
          for (const event of page.events) ctx.ui.setStatus("hosted-pi-event", `${boundedPublic(event.agentId)}: ${boundedPublic(event.operation)} @${event.revision}`);
          if (target === current.agentId) for (const delivery of page.deliveries) await deliverAndAcknowledge(ctx, delivery, fence);
        });
      pollSequences.set(target, cursor);
    }
  }

  async function deliverAndAcknowledge(ctx: ExtensionContext, delivery: any, fence: TargetFence) {
    const duplicate = delivered.has(delivery.dedupeId);
    if (delivery.kind === 4) { if (!duplicate) await prompts.deliver({ ...delivery, boundedPayload: new TextEncoder().encode(incomingRequestText(delivery)) }, fence); return; }
    if (!duplicate) {
      if (delivery.kind === 1) appendCommunicationView(incomingNote(communicationKey(delivery), delivery.source, delivery.boundedPayload));
      else appendCommunicationView(incomingControl(communicationKey(delivery), delivery.source, deliveryKindName(delivery.kind)));
    }
    const ack = await invokeTypedDeliveryForAck(requiredBinding(binding).agentId, delivery, async () => {
      if (delivery.hopLimit === 0) throw new Error("delivery hop budget exhausted");
      if (BigInt(Date.now()) > delivery.deadlineUnixMillis) throw new Error("delivery deadline expired");
      if (!duplicate) {
        if (delivery.kind !== 1) executeTypedDelivery(ctx, delivery.kind, safeText(delivery.boundedPayload));
        delivered.add(delivery.dedupeId);
        if (delivered.size > 512) delivered.delete(delivered.values().next().value!);
      }
    });
    const response = await requiredClient(client).request("bridgeDeliveryAckRequest", BridgeDeliveryAckRequestSchema, ack, fence);
    if (response.payload.case !== "bridgeDeliveryAckResponse" || !response.payload.value.accepted) throw new Error("delivery acknowledgement rejected");
    if (ack.delivered) {
      lastAckedSequence = maxBigInt(lastAckedSequence, delivery.sequence);
      appendDeliveryMarker(delivery.dedupeId, delivery.sequence, delivery.kind);
    }
  }

  function deliveredPrompt(dedupeId: string, sequence: bigint) {
    delivered.add(dedupeId);
    lastAckedSequence = maxBigInt(lastAckedSequence, sequence);
    if (delivered.size > 512) delivered.delete(delivered.values().next().value!);
    appendDeliveryMarker(dedupeId, sequence, 4);
  }

  function appendDeliveryMarker(dedupeId: string, sequence: bigint, kind?: number | string) {
    pi.appendEntry<DeliveryMarker>("hosted-pi-delivery-marker", { dedupeId, sequence: sequence.toString(), kind });
  }

  function restoreDeliveryMarkerFromKey(key: string) {
    const [dedupeId, sequence] = key.split("\0");
    if (!dedupeId) return;
    delivered.add(dedupeId);
    try { lastAckedSequence = maxBigInt(lastAckedSequence, BigInt(sequence)); } catch { /* legacy entries may not include a sequence */ }
  }

  function appendCommunicationView(view: CommunicationView) {
    const line = legacyCommunicationLine(view);
    if (timeline.add({ key: view.key, line })) pi.appendEntry<CommunicationEntry>("hosted-pi-communication", { key: view.key, line, view });
  }

  function reconnect(ctx: ExtensionContext) {
    if (reconnecting) return reconnecting;
    reconnecting = (async () => {
      ctx.ui.setStatus("hosted-pi-bridge", "hosted bridge reconnecting");
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          await client?.close();
          const current = requiredBinding(binding);
          client = new FramedClient(current, (frame) => schedulePush(ctx, frame)); pollClient = client;
          await client.open();
          const response = await client.request("bridgeConnectRequest", BridgeConnectRequestSchema, { agentId: current.agentId, runtimeId: current.runtimeId, incarnation: current.incarnation, piSessionId, lastAckedSequence });
          if (response.payload.case !== "bridgeConnectResponse" || !response.payload.value.accepted) throw new Error("hosted bridge reconnect rejected");
          const replacement = { handle: response.payload.value.agentHandle, fence: response.payload.value.fence };
          if (selfFence && (replacement.handle !== selfFence.handle || replacement.fence !== selfFence.fence)) throw new Error("idempotent reconnect unexpectedly rotated bridge fence");
          selfFence = replacement; fences.set(current.agentId, replacement);
          await lifecycle(BridgeLifecycleRequest_Event.READY);
          await prompts.retryCompletion();
          ctx.ui.setStatus("hosted-pi-bridge", "hosted bridge ready");
          return;
        } catch { await delay(Math.min(1000, 100 * 2 ** attempt)); }
      }
      ctx.ui.setStatus("hosted-pi-bridge", "hosted bridge degraded");
      throw new Error("hosted bridge reconnect attempts exhausted");
    })().finally(() => { reconnecting = undefined; });
    return reconnecting;
  }
}


async function loadBinding(): Promise<Binding> {
  const endpoint = requiredEnv("WS_SUBAGENTS_ENDPOINT");
  validateActorEndpoint(endpoint);
  const credentialPath = requiredEnv("WS_SUBAGENTS_CREDENTIAL_FILE");
  const stat = await lstat(credentialPath);
  if (!stat.isFile() || (stat.mode & 0o777) !== 0o600 || (typeof process.getuid === "function" && stat.uid !== process.getuid())) throw new Error("hosted bridge credential file is not owner-private");
  const parsed = JSON.parse(await readFile(credentialPath, "utf8")) as CredentialFile;
  const credential = Uint8Array.from(Buffer.from(parsed.credential_b64, "base64"));
  if (credential.byteLength !== 32) throw new Error("hosted bridge credential has invalid length");
  return { endpoint, credential, sessionId: requiredEnv("WS_SUBAGENTS_SESSION_ID"), generationId: requiredEnv("WS_SUBAGENTS_GENERATION_ID"), caller: requiredEnv("WS_SUBAGENTS_CALLER"), agentId: requiredEnv("WS_SUBAGENTS_AGENT_ID"), runtimeId: requiredEnv("WS_SUBAGENTS_RUNTIME_ID"), incarnation: BigInt(requiredEnv("WS_SUBAGENTS_INCARNATION")) };
}

function validateActorEndpoint(endpoint: string) {
  let url: URL;
  try { url = new URL(endpoint); } catch { throw new Error("hosted bridge endpoint must be a websocket URL"); }
  if (url.protocol !== "ws:" && url.protocol !== "wss:") throw new Error("hosted bridge endpoint must use ws or wss");
  if (url.pathname !== "/actors") throw new Error("hosted bridge endpoint path must be /actors");
  if (!url.hostname || !url.port) throw new Error("hosted bridge endpoint host and port are required");
}

export async function connectBridgeWithRetry(client: Pick<FramedClient, "request">, binding: Binding, piSessionId: string, lastAckedSequence: bigint, bridgeConnectSchema: DescMessage, attempts = 30, wait = delay) {
  let reason = "hosted bridge binding rejected";
  for (let attempt = 0; attempt < attempts; attempt++) {
    const response = await client.request("bridgeConnectRequest", bridgeConnectSchema, { agentId: binding.agentId, runtimeId: binding.runtimeId, incarnation: binding.incarnation, piSessionId, lastAckedSequence });
    if (response.payload.case !== "bridgeConnectResponse") throw new Error("unexpected hosted bridge connect response");
    if (response.payload.value.accepted) return response;
    reason = boundedPublic(response.payload.value.reason || reason, 120);
    if (attempt < attempts - 1) await wait(100);
  }
  throw new Error(`hosted bridge binding rejected: ${reason}`);
}

function delay(milliseconds: number) { return new Promise<void>((resolve) => setTimeout(resolve, milliseconds)); }
function maxBigInt(a: bigint, b: bigint) { return a > b ? a : b; }
function deliveryKindName(kind: number) { return kind === 1 ? "Tell" : kind === 2 ? "Abort" : kind === 3 ? "Shutdown" : kind === 4 ? "Prompt" : "Unknown"; }
function boundedPublic(value: string, max = 80) { const clean = value.replace(/[\r\n\t\x00]/g, " "); return clean.length > max ? `${clean.slice(0, Math.max(0, max - 1))}…` : clean; }
function safeText(bytes: Uint8Array): string { if (bytes.byteLength > MAX_TEXT) throw new Error("daemon payload exceeds bridge bound"); return textDecoder.decode(bytes); }

export function actorMessageModelResult(logical: { requestId: string; value: { dedupeId: string; chainId: string; sourceMutationSequence: bigint } }, value: any) {
  const requestId = requiredIdentifier(logical.requestId, "requestId");
  const dedupeId = requiredIdentifier(logical.value.dedupeId, "dedupeId");
  const chainId = requiredIdentifier(logical.value.chainId, "chainId");
  if (logical.value.sourceMutationSequence <= 0n) throw new Error("sourceMutationSequence is not a stable bounded identifier");
  const kind = requiredIdentifier(String(value.kind ?? ""), "kind");
  const source = peerView(value.source);
  const target = peerView(value.target);
  const sourceStableId = stablePeerId(value.source);
  const targetStableId = stablePeerId(value.target);
  return {
    accepted: Boolean(value.accepted),
    completed: Boolean(value.completed),
    result: safeText(value.boundedResult ?? new Uint8Array()),
    reason: String(value.reason ?? ""),
    requestId,
    dedupeId,
    chainId,
    sourceMutationSequence: logical.value.sourceMutationSequence.toString(),
    source: sourceStableId,
    target: targetStableId,
    kind,
    sourceStableId,
    sourceDisplayName: source.displayName,
    sourceRole: source.role,
    targetStableId,
    targetDisplayName: target.displayName,
    targetRole: target.role,
  };
}

function stablePeerId(peer: any): string { return requiredIdentifier(String(peer?.stableId ?? peer?.stable_id ?? ""), "peer"); }
function requiredIdentifier(value: string, label: string): string {
  if (value && /^[\x20-\x7e]{1,128}$/.test(value) && !/[\r\n\t\x00]/.test(value)) return value;
  throw new Error(`${label} is not a stable bounded identifier`);
}
function requiredEnv(name: string): string { const value = process.env[name]; if (!value) throw new Error(`missing hosted bridge environment ${name}`); return value; }
function requiredClient(value?: FramedClient): FramedClient { if (!value) throw new Error("hosted bridge is not ready"); return value; }
function requiredBinding(value?: Binding): Binding { if (!value) throw new Error("hosted bridge is not bound"); return value; }
function requiredFence(value?: TargetFence): TargetFence { if (!value) throw new Error("hosted bridge fence is unavailable"); return value; }
function requiredContext(value?: ExtensionContext): ExtensionContext { if (!value) throw new Error("hosted bridge context is unavailable"); return value; }
