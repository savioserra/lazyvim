import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { create, fromBinary, toBinary, type DescMessage } from "@bufbuild/protobuf";
import { randomUUID } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { dirname, isAbsolute, join, normalize } from "node:path";
import { Type } from "typebox";
type Envelope = any;
let EnvelopeSchema: DescMessage;
import { completeHostedEnvironment, ExactMutationSequencer, mutationScopeKey } from "../hosted-pi-bridge/handlers.ts";
import { legacyCommunicationLine, outgoingExchange, renderCommunicationCard, type CommunicationView } from "../hosted-pi-bridge/communication-ui.ts";
import { publicAgentView, registerClientHandlers } from "./handlers.ts";

const MAX_FRAME = 64 * 1024;
const MAX_TEXT = 16 * 1024;
const NORMAL_TIMEOUT = 5_000;

type Session = { sessionId: string; generationId: string; caller: string; credential: Uint8Array };
type Fence = { handle: string; fence: bigint };
type CredentialFile = { credential_b64: string };
type CommunicationEntry = { key: string; line?: string; view?: CommunicationView };
type ActorAskPendingEntry = { key: string; requestId: string; dedupeId: string; chainId: string; sourceMutationSequence: string; source?: string; target?: string; kind: string; prompt: string; targetPeer?: PeerMetadata };
export type ActorAskCompletionMessage = { key: string; requestId: string; dedupeId: string; chainId: string; sourceMutationSequence: string; source?: string; target?: string; kind: string; terminal: "replied" | "failed"; nextAction: string; prompt: string; answer: string; reason?: string; communicationView: CommunicationView };
type PeerMetadata = { stableId?: string; displayName: string; role?: string; authoritative: boolean };
export type ActorRosterItem = { agentId: string; displayName: string; role?: string; lifecycle: string; revision: bigint };
export type ActorClientRosterState = { connection: "disconnected" | "connecting" | "connected"; epoch: bigint; sequence: bigint; agents: Map<string, ActorRosterItem>; overflow: number; render: string };
export type ActorClientRosterEvent = { type: "CONNECTING" | "CONNECTED" | "DISCONNECTED" } | { type: "ROSTER_FRAME"; frame: any };

export function initialActorClientRosterState(): ActorClientRosterState { return { connection: "disconnected", epoch: 0n, sequence: 0n, agents: new Map(), overflow: 0, render: "" }; }
export function reduceActorClientRoster(state: ActorClientRosterState, event: ActorClientRosterEvent): ActorClientRosterState {
  if (event.type === "CONNECTING") return { ...state, connection: "connecting", render: renderActorClientStatus({ ...state, connection: "connecting" }) };
  if (event.type === "CONNECTED") return { ...state, connection: "connected", render: renderActorClientStatus({ ...state, connection: "connected" }) };
  if (event.type === "DISCONNECTED") return { ...state, connection: "disconnected", render: "" };
  const frame = event.frame ?? {}; const epoch = BigInt(frame.epoch ?? 0); const sequence = BigInt(frame.sequence ?? 0);
  if (epoch < state.epoch || (epoch === state.epoch && sequence < state.sequence)) return state;
  const agents = new Map(epoch > state.epoch || frame.operation === 2 ? [] : state.agents);
  if (frame.operation === 3) { const item = rosterItemFromFrame(frame); if (item) agents.set(item.agentId, item); }
  if (frame.operation === 4) { const agentId = sanitizeStatusText(frame.agentId || frame.agent?.agentId, 64); if (agentId) agents.delete(agentId); }
  const next = { ...state, epoch, sequence, agents, connection: "connected" as const, overflow: 0, render: "" };
  next.render = renderActorClientStatus(next); return next;
}
export function renderActorClientStatus(state: ActorClientRosterState, max = 120): string {
  if (state.connection === "connecting") return "actors connecting";
  if (state.connection !== "connected") return "";
  const items = [...state.agents.values()].sort((a, b) => a.agentId.localeCompare(b.agentId));
  const parts = items.map((item) => `${item.displayName}:${item.lifecycle}`);
  let output = parts.length ? `actors ${parts.join(" ")}` : "actors none"; let overflow = 0;
  while (output.length > max && parts.length) { parts.pop(); overflow++; output = parts.length ? `actors ${parts.join(" ")} +${overflow}` : `actors +${overflow}`; }
  state.overflow = overflow; return sanitizeStatusText(output, max) ?? "actors";
}
function rosterItemFromFrame(frame: any): ActorRosterItem | undefined { const agent = frame.agent ?? {}; const agentId = sanitizeStatusText(frame.agentId || agent.agentId, 64); if (!agentId) return undefined; const displayName = sanitizeStatusText(agent.displayName || agent.hostedPiRuntime?.displayName || agentId, 32) ?? agentId; const role = sanitizeStatusText(agent.role || agent.hostedPiRuntime?.role, 24); return { agentId, displayName, role, lifecycle: rosterLifecycle(frame.status, agent), revision: BigInt(agent.lifecycleRevision ?? 0) }; }
function rosterLifecycle(status: unknown, agent: any): string { const value = sanitizeStatusText(status, 24); if (value) return `[redacted] ${value}`; const state = Number(agent?.hostedPiRuntime?.state ?? 0); const names: Record<number, string> = { 1: "inactive", 2: "starting", 3: "ready", 4: "degraded", 5: "stopping", 6: "stopped" }; return `[redacted] ${names[state] ?? "registered"}`; }
function sanitizeStatusText(value: unknown, max: number): string | undefined { if (typeof value !== "string") return undefined; const clean = value.replace(/[\0\r\n\t\u001b\u202a-\u202e\u2066-\u2069]/g, " ").replace(/[^\p{L}\p{N} .:_+\-\[\]]/gu, " ").replace(/\s+/g, " ").trim(); return clean ? clean.slice(0, max) : undefined; }
export function actorAskCompletionContent(details: ActorAskCompletionMessage): string {
  const lines = [`Actor Ask ${details.terminal}: ${details.source || "client"} -> ${details.target || "actor"} (${details.kind})`, `requestId=${details.requestId}`, `dedupeId=${details.dedupeId}`, `chainId=${details.chainId}`, `sourceMutationSequence=${details.sourceMutationSequence}`, `source=${details.source || ""}`, `target=${details.target || ""}`, `kind=${details.kind}`, `terminal=${details.terminal}`, `nextAction=${details.nextAction}`, "prompt:", details.prompt, "answer:", details.answer];
  if (details.reason) lines.splice(10, 0, `reason=${details.reason}`);
  return lines.join("\n");
}

export class ActorClientConversationLog {
  private readonly seenEntries = new Set<string>();
  private readonly pending = new Map<string, ActorAskPendingEntry>();
  private readonly terminal = new Set<string>();
  private readonly pi: { appendEntry<T>(customType: string, data: T): void; sendMessage?(message: { customType: string; content: string; display?: boolean; details?: unknown }, options?: { deliverAs?: "steer" | "followUp" | "nextTurn"; triggerTurn?: boolean }): void | Promise<void> };
  private readonly setPendingStatus?: (count: number) => void;
  constructor(pi: { appendEntry<T>(customType: string, data: T): void; sendMessage?(message: { customType: string; content: string; display?: boolean; details?: unknown }, options?: { deliverAs?: "steer" | "followUp" | "nextTurn"; triggerTurn?: boolean }): void | Promise<void> }, setPendingStatus?: (count: number) => void) { this.pi = pi; this.setPendingStatus = setPendingStatus; }
  restore(entries: Array<{ type?: string; customType?: string; data?: Partial<ActorAskPendingEntry | ActorAskCompletionMessage>; content?: string; details?: Partial<ActorAskCompletionMessage> }>) {
    for (const entry of entries) {
      const data = (entry.data ?? entry.details) as Partial<ActorAskPendingEntry | ActorAskCompletionMessage> | undefined;
      if (entry.type === "custom" && entry.customType === "actor-client-communication" && typeof data?.key === "string") this.seenEntries.add(data.key);
      if (entry.type === "custom" && entry.customType === "actor-client-ask-pending" && typeof data?.key === "string" && !this.terminal.has(data.key)) this.pending.set(data.key, data as ActorAskPendingEntry);
      if (entry.type === "custom" && entry.customType === "actor-client-ask-completion" && typeof data?.key === "string") { this.terminal.add(data.key); this.pending.delete(data.key); this.seenEntries.add(data.key); }
    }
    this.updateStatus();
  }
  append(view: CommunicationView): boolean {
    if (this.seenEntries.has(view.key) || this.terminal.has(view.key) || this.pending.has(view.key)) return false;
    this.seenEntries.add(view.key);
    this.pi.appendEntry<CommunicationEntry>("actor-client-communication", { key: view.key, line: legacyCommunicationLine(view), view });
    return true;
  }
  recordAskPending(entry: ActorAskPendingEntry): boolean {
    if (this.terminal.has(entry.key) || this.pending.has(entry.key)) return false;
    this.pending.set(entry.key, entry);
    this.pi.appendEntry<ActorAskPendingEntry>("actor-client-ask-pending", entry);
    this.updateStatus();
    return true;
  }
  async complete(entry: { key: string; reply: string; completed: boolean; reason?: string; source?: PeerMetadata; target?: PeerMetadata; kind?: string; requestId?: string; dedupeId?: string; chainId?: string; sourceMutationSequence?: string }): Promise<boolean> {
    if (this.terminal.has(entry.key)) return false;
    const pending = this.pending.get(entry.key);
    const target = entry.target ?? pending?.targetPeer ?? pending?.target ?? "Unknown actor";
    const terminal = entry.completed ? "replied" : "failed";
    const view = outgoingExchange({ key: entry.key, target, body: pending?.prompt ?? `Ask request ${entry.requestId ?? pending?.requestId ?? entry.key}`, reply: entry.reply, accepted: entry.completed, completed: entry.completed, mode: "ask", reason: entry.reason });
    const details: ActorAskCompletionMessage = {
      key: entry.key,
      requestId: entry.requestId ?? pending?.requestId ?? entry.key.replace(/^actor-client:/, ""),
      dedupeId: entry.dedupeId ?? pending?.dedupeId ?? "",
      chainId: entry.chainId ?? pending?.chainId ?? "",
      sourceMutationSequence: entry.sourceMutationSequence ?? pending?.sourceMutationSequence ?? "",
      source: entry.source?.displayName ?? pending?.source,
      target: entry.target?.displayName ?? pending?.target,
      kind: entry.kind ?? pending?.kind ?? "Ask",
      terminal,
      nextAction: entry.completed ? "continue with the returned answer" : "retry or choose another actor if needed",
      prompt: pending?.prompt ?? "",
      answer: entry.reply,
      reason: entry.reason,
      communicationView: view,
    };
    const content = actorAskCompletionContent(details);
    await this.pi.sendMessage?.({ customType: "actor-client-ask-completion", content, display: true, details }, { deliverAs: "followUp", triggerTurn: true });
    this.terminal.add(entry.key); this.seenEntries.add(entry.key); this.pending.delete(entry.key); this.updateStatus();
    return true;
  }
  private updateStatus() { this.setPendingStatus?.(this.pending.size); }
}

class Client {
  private socket?: WebSocket;
  private sequence = 0n;
  private tail = Promise.resolve();
  private readonly endpoint: string;
  private session: Session;
  private readonly pending = new Map<string, { sequence: bigint; resolve: (value: Envelope) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private onPush?: (envelope: Envelope) => void;

  constructor(endpoint: string, session: Session, onPush?: (envelope: Envelope) => void) {
    this.endpoint = endpoint;
    this.session = session;
    this.onPush = onPush;
  }
  setSession(session: Session) { this.session = session; }
  setPushHandler(onPush?: (envelope: Envelope) => void) { this.onPush = onPush; }
  connected() { return this.socket?.readyState === WebSocket.OPEN; }
  async open() {
    validateActorEndpoint(this.endpoint);
    this.socket = await new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(this.endpoint);
      socket.binaryType = "arraybuffer";
      const timer = setTimeout(() => { socket.close(); reject(new Error("client daemon websocket timeout")); }, NORMAL_TIMEOUT);
      socket.addEventListener("open", () => { clearTimeout(timer); socket.addEventListener("message", (event) => void this.receive(event)); socket.addEventListener("close", () => this.failPending(new Error("client daemon disconnected")), { once: true }); socket.addEventListener("error", () => this.failPending(new Error("client daemon websocket error")), { once: true }); resolve(socket); }, { once: true });
      socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("client daemon websocket error")); }, { once: true });
    });
  }
  async close() { const socket = this.socket;this.socket=undefined;this.failPending(new Error("client is disconnected"));if(!socket)return;if(socket.readyState===WebSocket.CLOSED)return;socket.close();await new Promise<void>((resolve)=>{const timer=setTimeout(resolve,500);socket.addEventListener("close",()=>{clearTimeout(timer);resolve();},{once:true});}); }
  async reopen() { await this.close();await this.open(); }
  request<T>(payloadCase: string, schema: DescMessage, value: T, options: { fence?: Fence; requestId?: string; timeout?: number } = {}): Promise<Envelope> {
    const operation = this.tail.then(() => this.requestNow(payloadCase, schema, value, options));
    this.tail = operation.then(() => undefined, () => undefined);
    return operation;
  }
  private async requestNow<T>(payloadCase: string, schema: DescMessage, value: T, options: { fence?: Fence; requestId?: string; timeout?: number }): Promise<Envelope> {
    const socket=this.socket;if(!socket)throw new Error("client is disconnected");
    this.sequence++;const timeout=options.timeout??NORMAL_TIMEOUT;
    const envelope=create(EnvelopeSchema,{protocolMajor:1,protocolMinor:1,sessionId:this.session.sessionId,generationId:this.session.generationId,requestId:options.requestId??randomUUID(),deadlineUnixMillis:BigInt(Date.now()+timeout),sequence:this.sequence,callerIdentity:this.session.caller,agentHandle:options.fence?.handle??"",agentFence:options.fence?.fence??0n,sessionCredential:this.session.credential,payload:{case:payloadCase as never,value:create(schema,value as never) as never}});
    const bytes=toBinary(EnvelopeSchema,envelope);if(bytes.byteLength>MAX_FRAME)throw new Error("client request exceeds frame bound");const frame=Buffer.alloc(bytes.byteLength+4);frame.writeUInt32BE(bytes.byteLength);frame.set(bytes,4);
    try { socket.send(frame);const response=await this.waitForResponse(String(envelope.requestId), this.sequence, timeout);if(response.payload.case==="protocolError")throw new Error(response.payload.value.message||"client request rejected");return response; }
    catch(error){if(this.socket===socket){this.socket=undefined;socket.close();}throw error;}
  }
  private waitForResponse(requestId: string, sequence: bigint, timeout: number): Promise<Envelope> { return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pending.delete(requestId); reject(new Error("client response timeout")); }, timeout); this.pending.set(requestId, { sequence, resolve, reject, timer }); }); }
  private async receive(event: MessageEvent) { let response: Envelope; try { response = fromBinary(EnvelopeSchema, await parseFrame(event.data)); } catch (error) { this.failPending(error instanceof Error ? error : new Error("client response frame bound violated")); return; } if (response.payload?.case === "actorMessageReplyFrame") { this.onPush?.(response); return; } const requestId = String(response.requestId ?? ""); const pending = requestId ? this.pending.get(requestId) : undefined; if (pending) { if (response.sequence !== pending.sequence) { clearTimeout(pending.timer); this.pending.delete(requestId); pending.reject(new Error("client response correlation mismatch")); return; } clearTimeout(pending.timer); this.pending.delete(requestId); pending.resolve(response); return; } this.onPush?.(response); }
  private failPending(error: Error) { for (const [requestId, pending] of this.pending) { clearTimeout(pending.timer); pending.reject(error); this.pending.delete(requestId); } }
}

export default async function wsActorClient(pi: ExtensionAPI) {
  // A hosted aggregate uses the hosted bridge's canonical actor tools. The
  // regular client must remain inert there or duplicate global discovery would
  // collide with the hosted tool surface.
  if (completeHostedEnvironment(process.env)) return;
  const discovered=discoverManagedPaths();
  let activeEndpoint=discovered.endpoint;
  const proto = await import("./subagents_pb.ts");
  const { ActorControlRequestSchema, ActorMessageRequestSchema, ActorMessageRequest_Mode, AttachRequestSchema, ClientAgentRosterRequestSchema, ClientSessionRequestSchema, ClientSessionRequest_Operation, HostedAdminRequestSchema, HostedAdminRequest_Operation, ListAgentsRequestSchema, ResolveAgentRequestSchema, SubscribeAgentRequestSchema, UnsubscribeAgentRequestSchema } = proto;
  EnvelopeSchema = proto.EnvelopeSchema;
  let admin:Client|undefined;let regular:Client|undefined;let session:Session|undefined;let context:ExtensionContext|undefined;
  const fences=new Map<string,Fence>();const peerCache=new Map<string,PeerMetadata>();let sourcePeer:PeerMetadata|undefined;const mutations=new ExactMutationSequencer();let rosterState=initialActorClientRosterState();
  const applyRosterEvent=(event:ActorClientRosterEvent)=>{rosterState=reduceActorClientRoster(rosterState,event);context?.ui.setStatus("actor-client",rosterState.render||undefined);};
  const setPendingAskStatus=(count:number)=>context?.ui.setStatus("actor-client-asks",count?`actor asks ${count} pending`:undefined);
  const handlePush=(envelope:Envelope)=>{if(envelope.payload?.case==="clientAgentRosterFrame")applyRosterEvent({type:"ROSTER_FRAME",frame:envelope.payload.value});if(envelope.payload?.case==="actorMessageReplyFrame"){const value=envelope.payload.value;void conversation.complete({key:`actor-client:${value.originalRequestId||envelope.requestId}`,reply:new TextDecoder().decode(value.boundedResult??new Uint8Array()),completed:!!value.completed,reason:value.reason,source:peerFromProto(value.source),target:peerFromProto(value.target),kind:value.kind,requestId:value.originalRequestId||envelope.requestId,dedupeId:value.dedupeId,chainId:value.chainId,sourceMutationSequence:String(value.sourceMutationSequence??"")});}};
  const adminSession:Session={sessionId:"",generationId:"",caller:"client-bootstrap",credential:new Uint8Array()};

  pi.registerEntryRenderer<CommunicationEntry>("actor-client-communication", (entry, _options, theme) => entry.data?.view ? renderCommunicationCard(entry.data.view, theme) : { render: () => [entry.data?.line ?? "actor communication unavailable"], invalidate() {} });
  pi.registerMessageRenderer<ActorAskCompletionMessage>("actor-client-ask-completion", (message, _options, theme) => renderCommunicationCard((message.details as ActorAskCompletionMessage | undefined)?.communicationView ?? outgoingExchange({key:"actor-client:unavailable",target:"Unknown actor",body:String(message.content ?? "Actor Ask completed"),accepted:false,completed:false,mode:"ask"}), theme));
  const conversation = new ActorClientConversationLog(pi, setPendingAskStatus);

  const createActor=async(agentId:string,projectDirectory:string,displayName?:string,role?:string,nodeIdentity?:string)=>{
    validateAgentID(agentId);if(nodeIdentity!==undefined){validateNodeIdentity(nodeIdentity);validateRemoteProject(projectDirectory);}else await validateProject(projectDirectory);if(displayName!==undefined)validateDisplayMetadata(displayName,"display name",80);if(role!==undefined)validateDisplayMetadata(role,"role",64);
    const response=await required(admin).request("hostedAdminRequest",HostedAdminRequestSchema,{operation:HostedAdminRequest_Operation.START,agentId,projectDirectory,trustProject:true,displayName:displayName?.trim()??"",role:role?.trim()??"",targetNode:nodeIdentity?.trim()??""},{timeout:30_000});
    if(response.payload.case!=="hostedAdminResponse")throw new Error("unexpected actor create response");
    return {accepted:response.payload.value.accepted,agentId:response.payload.value.agentId,reason:response.payload.value.reason};
  };
  const cacheAuthoritativePeer=(key:string,peer:PeerMetadata|undefined)=>{if(peer?.authoritative)peerCache.set(key,peer);return peer;};
  const peerFromProto=(peer:any):PeerMetadata|undefined=>{const stable=safePeerText(peer?.stableId,128);const display=naturalPeerText(peer?.displayName,80);const role=naturalRoleText(peer?.role,64);if(!display||display===stable||isGenericRole(display))return undefined;return {stableId:stable,displayName:display,role,authoritative:true};};
  const peerFromAgent=(agent:any):PeerMetadata|undefined=>{const display=naturalPeerText(agent?.displayName,80);const role=naturalRoleText(agent?.role,64);if(!display||display===agent?.agentId||isGenericRole(display))return undefined;return {stableId:safePeerText(agent?.agentId,128),displayName:display,role,authoritative:true};};
  const cachePeer=(agent:any)=>{const view=publicAgentView(agent);cacheAuthoritativePeer(view.agentId,peerFromAgent(view));return view;};
  const list=async()=>{const response=await required(regular).request("listAgentsRequest",ListAgentsRequestSchema,{});if(response.payload.case!=="listAgentsResponse")throw new Error("unexpected actor list response");return response.payload.value.agents.map(cachePeer);};
  const resolve=async(target:string)=>{validateAgentID(target);const response=await required(regular).request("resolveAgentRequest",ResolveAgentRequestSchema,{agentId:target});if(response.payload.case!=="resolveAgentResponse")throw new Error("unexpected actor resolve response");return response.payload.value;};
  const status=async(agentId:string)=>{validateAgentID(agentId);const cached=rosterState.agents.get(agentId);if(cached)return {accepted:true,agentId:cached.agentId,displayName:cached.displayName,role:cached.role,lifecycle:cached.lifecycle,revision:String(cached.revision)};const resolved=await resolve(agentId);const found=resolved?.agent;if(found?.agentId)return cachePeer(found);return {accepted:false,agentId,reason:"agent not found or access denied"};};
  const authoritativePeer=async(agentId:string)=>{const cached=peerCache.get(agentId);if(cached?.authoritative)return cached;const result=await status(agentId) as any;const resolved=peerFromAgent(result);if(resolved)return cacheAuthoritativePeer(agentId,resolved)!;throw new Error("authoritative actor display metadata is required");};
  const stop=async(agentId:string)=>{validateAgentID(agentId);const response=await required(admin).request("hostedAdminRequest",HostedAdminRequestSchema,{operation:HostedAdminRequest_Operation.STOP,agentId},{timeout:30_000});if(response.payload.case!=="hostedAdminResponse")throw new Error("unexpected actor stop response");fences.delete(agentId);return {accepted:response.payload.value.accepted,agentId,state:response.payload.value.runtime?.state??0,reason:response.payload.value.reason};};
  const attach=async(agentId:string)=>{validateAgentID(agentId);const cached=fences.get(agentId);if(cached)return cached;const response=await required(regular).request("attachRequest",AttachRequestSchema,{agentId,requestedCapabilities:["observe","send","ask","prompt","control_abort","control_shutdown"]});if(response.payload.case!=="attachResponse"||!response.payload.value.agentHandle)throw new Error("actor attach rejected");const fence={handle:response.payload.value.agentHandle,fence:response.payload.value.fence};fences.set(agentId,fence);return fence;};
  const subscribe=async(agentId:string)=>{const fence=await attach(agentId);const response=await required(regular).request("subscribeAgentRequest",SubscribeAgentRequestSchema,{agentId,afterRevision:0n},{fence});if(response.payload.case!=="agentOperationResponse")throw new Error("unexpected subscribe response");return {completed:response.payload.value.completed,reason:response.payload.value.reason};};
  const unsubscribe=async(agentId:string)=>{const fence=await attach(agentId);const response=await required(regular).request("unsubscribeAgentRequest",UnsubscribeAgentRequestSchema,{agentId},{fence});if(response.payload.case!=="agentOperationResponse")throw new Error("unexpected unsubscribe response");return {completed:response.payload.value.completed,reason:response.payload.value.reason};};
  const control=async(agentId:string,intent:number)=>{validateAgentID(agentId);const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{intent,target:agentId,dedupeId:randomUUID(),chainId:randomUUID(),sourceMutationSequence,hopLimit:2}}),async(logical)=>{const response=await required(regular).request("actorControlRequest",ActorControlRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:NORMAL_TIMEOUT});if(response.payload.case!=="actorMessageResponse")throw new Error("unexpected actor control response");return {accepted:response.payload.value.accepted,completed:response.payload.value.completed,reason:response.payload.value.reason,kind:response.payload.value.kind,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence)};},async()=>required(regular).reopen());};
  const send=async(agentId:string,message:string,options:{appendConversation?:boolean}={})=>{validateAgentID(agentId);const text=message.trim();const encoded=new TextEncoder().encode(text);if(!encoded.byteLength||encoded.byteLength>MAX_TEXT)throw new Error("message must be non-empty and at most 16 KiB");const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{mode:ActorMessageRequest_Mode.TELL,target:agentId,boundedPayload:encoded,dedupeId:randomUUID(),chainId:randomUUID(),hopLimit:8,sourceMutationSequence}}),async(logical)=>{const started=Date.now();const response=await required(regular).request("actorMessageRequest",ActorMessageRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:NORMAL_TIMEOUT});if(response.payload.case!=="actorMessageResponse")throw new Error("unexpected actor message response");const value=response.payload.value;const targetPeer=peerFromProto(value.target)??await authoritativePeer(agentId);const protoSource=peerFromProto(value.source);if(protoSource)sourcePeer=protoSource;if(targetPeer.authoritative)cacheAuthoritativePeer(agentId,targetPeer);const view=outgoingExchange({key:`actor-client:${logical.requestId}`,target:targetPeer,body:text,accepted:value.accepted,completed:value.completed,mode:"tell",reason:value.reason,durationMillis:Date.now()-started});if(options.appendConversation!==false)conversation.append(view);return {accepted:value.accepted,completed:value.completed,reason:value.reason,source:protoSource?.displayName,target:targetPeer.authoritative?targetPeer.displayName:undefined,kind:value.kind,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence),communicationView:view};},async()=>required(regular).reopen());};
  const ask=async(agentId:string,prompt:string,options:{appendConversation?:boolean}={})=>{validateAgentID(agentId);const text=prompt.trim();const encoded=new TextEncoder().encode(text);if(!encoded.byteLength||encoded.byteLength>MAX_TEXT)throw new Error("prompt must be non-empty and at most 16 KiB");const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{mode:ActorMessageRequest_Mode.ASK,target:agentId,boundedPayload:encoded,dedupeId:randomUUID(),chainId:randomUUID(),hopLimit:8,sourceMutationSequence}}),async(logical)=>{const started=Date.now();const response=await required(regular).request("actorMessageRequest",ActorMessageRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:NORMAL_TIMEOUT});if(response.payload.case!=="actorMessageResponse")throw new Error("unexpected actor message response");const value=response.payload.value;const targetPeer=peerFromProto(value.target)??await authoritativePeer(agentId);const protoSource=peerFromProto(value.source);if(protoSource)sourcePeer=protoSource;if(targetPeer.authoritative)cacheAuthoritativePeer(agentId,targetPeer);const answer=value.boundedResult?.byteLength?new TextDecoder().decode(value.boundedResult):undefined;const key=`actor-client:${logical.requestId}`;const view=outgoingExchange({key,target:targetPeer,body:text,reply:answer,accepted:value.accepted,completed:value.completed,mode:"ask",reason:value.reason,durationMillis:Date.now()-started});if(options.appendConversation!==false&&value.accepted&&!value.completed)conversation.recordAskPending({key,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence),source:protoSource?.displayName,target:targetPeer.authoritative?targetPeer.displayName:undefined,kind:value.kind||"Ask",prompt:text,targetPeer});if(options.appendConversation!==false&&(!value.accepted||value.completed))void conversation.complete({key,reply:answer??"",completed:!!value.completed&&value.accepted,reason:value.reason,source:protoSource,target:targetPeer,kind:value.kind||"Ask",requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence)});return {accepted:value.accepted,completed:value.completed,awaitingReply:value.accepted&&!value.completed,answer,reason:value.reason,source:protoSource?.displayName,target:targetPeer.authoritative?targetPeer.displayName:undefined,kind:value.kind,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence),communicationView:view};},async()=>required(regular).reopen());};
  const attachCommand=async(agentId:string)=>attach(agentId);
  const connectEndpoint=async(target:string)=>{const endpoint=actorEndpointFromTarget(target);if(endpoint)validateActorEndpoint(endpoint);activeEndpoint=endpoint;clientGeneration++;await resetClients(true);return {accepted:true,endpoint:endpoint?publicEndpointLabel(endpoint):"managed-local"};};
  let bootstrap:Promise<void>|undefined;
  let clientGeneration=0;
  const resetClients=async(closeSession:boolean)=>{const activeRegular=regular;const activeAdmin=admin;const activeSession=session;admin=undefined;regular=undefined;session=undefined;fences.clear();peerCache.clear();sourcePeer=undefined;applyRosterEvent({type:"DISCONNECTED"});if(closeSession&&activeRegular&&activeSession){try{await activeRegular.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.CLOSE},{timeout:NORMAL_TIMEOUT});}catch{}}await Promise.all([activeRegular?.close().catch(()=>{}),activeAdmin?.close().catch(()=>{})]);};
  const ensureStarted=async()=>{if(admin?.connected()&&regular?.connected()&&session)return;if(bootstrap)return bootstrap;const generation=clientGeneration;bootstrap=(async()=>{await resetClients(true);applyRosterEvent({type:"CONNECTING"});const paths=await waitForManagedPaths(discovered,activeEndpoint);const adminCredential=await loadCredential(paths.adminPath);adminSession.credential=adminCredential;const nextAdmin=new Client(paths.endpoint,adminSession);let nextRegular:Client|undefined;let nextSession:Session|undefined;let nextSessionClosed=false;try{await nextAdmin.open();const opened=await nextAdmin.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.OPEN});if(opened.payload.case!=="clientSessionResponse"||!opened.payload.value.accepted||opened.payload.value.sessionCredential.byteLength!==32)throw new Error("client session bootstrap rejected");nextSession={sessionId:opened.payload.value.sessionId,generationId:opened.payload.value.generationId,caller:opened.payload.value.callerIdentity,credential:opened.payload.value.sessionCredential};nextRegular=new Client(paths.endpoint,nextSession,handlePush);await nextRegular.open();if(generation!==clientGeneration||!context){await nextRegular.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.CLOSE}).then(()=>{nextSessionClosed=true;},()=>{});throw new Error("client session closed during bootstrap");}admin=nextAdmin;session=nextSession;regular=nextRegular;sourcePeer=peerFromProto((opened.payload.value as any).clientPeer??(opened.payload.value as any).source??(opened.payload.value as any).peer);applyRosterEvent({type:"CONNECTED"});const rosterResponse=await nextRegular.request("clientAgentRosterRequest",ClientAgentRosterRequestSchema,{lastEpoch:rosterState.epoch,afterSequence:rosterState.sequence});if(rosterResponse.payload.case!=="agentOperationResponse"||!rosterResponse.payload.value.completed)throw new Error(rosterResponse.payload.value?.reason||"actor roster subscription rejected");}catch(error){if(nextSession&&!nextSessionClosed){const closer=new Client(paths.endpoint,nextSession);try{await closer.open();await closer.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.CLOSE});}catch{}await closer.close().catch(()=>{});}await Promise.all([nextRegular?.close().catch(()=>{}),nextAdmin.close().catch(()=>{})]);applyRosterEvent({type:"DISCONNECTED"});throw error;}})();try{await bootstrap;}finally{bootstrap=undefined;}};
  const withReady=<A extends unknown[],R>(fn:(...args:A)=>Promise<R>)=>async(...args:A)=>{try{await ensureStarted();return await fn(...args);}catch(error){await resetClients(false);throw error;}};

  const target=Type.Object({agentId:Type.String({minLength:1})});const actorTarget=Type.Object({target:Type.String({minLength:1})});const actorTask=Type.Object({target:Type.String({minLength:1}),message:Type.String({minLength:1,maxLength:MAX_TEXT})});
  registerClientHandlers(pi as any,{connect:connectEndpoint,create:withReady(createActor),list:withReady(list),resolve:withReady(resolve),send:withReady(send),ask:withReady(ask),status:withReady(status),health:withReady(status),attach:withReady(attachCommand),stop:withReady(stop),subscribe:withReady(subscribe),unsubscribe:withReady(unsubscribe),control:withReady(control)},{empty:Type.Object({}),target,actorTarget,actorTask,create:Type.Object({agentId:Type.String({minLength:1}),projectDirectory:Type.String({minLength:1}),displayName:Type.Optional(Type.String({minLength:1,maxLength:80})),role:Type.Optional(Type.String({minLength:1,maxLength:64})),nodeIdentity:Type.Optional(Type.String({minLength:1,maxLength:64}))})});

  pi.on("session_start",async(_event,ctx)=>{clientGeneration++;context=ctx;conversation.restore(ctx.sessionManager.getEntries() as any);try{await ensureStarted();}catch(error){ctx.ui.setStatus("actor-client",undefined);}});
  pi.on("session_shutdown",async(_event,ctx)=>{clientGeneration++;try{if(regular&&session)await regular.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.CLOSE});}catch{}await Promise.all([regular?.close(),admin?.close()]);regular=undefined;admin=undefined;session=undefined;fences.clear();peerCache.clear();sourcePeer=undefined;ctx.ui.setStatus("actor-client",undefined);context=undefined;});
}

function discoverManagedPaths(){const home=process.env.HOME;if(!home||!isAbsolute(home))throw new Error("HOME is required for managed actor discovery");const stateAdmin=join(home,".local/state/workstation/subagents/admin/credential.json");const runtimeAdmin=process.env.XDG_RUNTIME_DIR?join(process.env.XDG_RUNTIME_DIR,"ws-subagents","admin","credential.json"):stateAdmin;const runtimeConfig=process.env.XDG_RUNTIME_DIR?join(process.env.XDG_RUNTIME_DIR,"ws-subagents","config.toml"):undefined;const stateConfig=join(home,".config","workstation","subagents","config.toml");return {endpoint:"",adminPaths:[runtimeAdmin,stateAdmin],configPaths:[runtimeConfig,stateConfig].filter(Boolean) as string[]};}
async function waitForManagedPaths(discovered:{endpoint:string;adminPaths:string[];configPaths:string[]},endpoint:string){const deadline=Date.now()+15_000;let last:unknown;while(Date.now()<deadline){const selectedEndpoint=endpoint||await discoverEndpointFromConfig(discovered.configPaths).catch((error)=>{last=error;return "";});for(const adminPath of discovered.adminPaths){try{validateActorEndpoint(selectedEndpoint);await validatePrivateFile(adminPath,"admin credential file");return {endpoint:selectedEndpoint,adminPath};}catch(error){last=error;}}await new Promise((resolve)=>setTimeout(resolve,250));}throw new Error(`managed actor service is not ready (${last instanceof Error?last.message:"unknown readiness failure"})`);}
async function loadCredential(path:string){await validatePrivateFile(path,"admin credential file");const parsed=JSON.parse(await readFile(path,"utf8")) as CredentialFile;const value=Uint8Array.from(Buffer.from(parsed.credential_b64,"base64"));if(value.byteLength!==32)throw new Error("admin credential has invalid length");return value;}
async function validatePrivateFile(path:string,label:string){if(!isAbsolute(path))throw new Error(`${label} path must be absolute`);await validateNoSymlinkAncestors(dirname(path),label);const stat=await lstat(path);const uid=typeof process.getuid==="function"?process.getuid():undefined;if(!stat.isFile()||(stat.mode&0o777)!==0o600||(uid!==undefined&&stat.uid!==uid))throw new Error(`${label} is not owner-private`);}
async function discoverEndpointFromConfig(paths:string[]){for(const path of paths){try{await validatePrivateFile(path,"actor config file");const text=await readFile(path,"utf8");const host=text.match(/^bind_host\s*=\s*"([^"]+)"/m)?.[1]||"127.0.0.1";const port=text.match(/^actor_endpoint_port\s*=\s*([0-9]+)/m)?.[1]||"17213";return `ws://${host}:${port}/actors`;}catch{}}return "ws://127.0.0.1:17213/actors";}
function validateActorEndpoint(endpoint:string){let url:URL;try{url=new URL(endpoint);}catch{throw new Error("actor endpoint must be a websocket URL");}if(url.protocol!=="ws:"&&url.protocol!=="wss:")throw new Error("actor endpoint must use ws or wss");if(url.pathname!=="/actors")throw new Error("actor endpoint path must be /actors");if(!url.hostname||!url.port)throw new Error("actor endpoint host and port are required");}
function actorEndpointFromTarget(target:string){const value=target.trim();if(!value)return "";if(/^wss?:\/\//.test(value))return value;if(!/^[A-Za-z0-9.-]{1,253}$/.test(value))throw new Error("actor connect target must be a clean host or websocket URL");return `ws://${value}:17213/actors`;}
function publicEndpointLabel(endpoint:string){const url=new URL(endpoint);return `${url.protocol}//${url.hostname}:${url.port}${url.pathname}`;}
async function validateNoSymlinkAncestors(path:string,label:string){const uid=typeof process.getuid==="function"?process.getuid():undefined;const parts=path.split("/").filter(Boolean);let current="";for(const part of parts){current+=`/${part}`;const stat=await lstat(current);if(stat.isSymbolicLink()||!stat.isDirectory())throw new Error(`${label} ancestor is unsafe`);if(uid!==undefined&&stat.uid!==uid&&stat.uid!==0)throw new Error(`${label} ancestor has foreign ownership`);if((stat.mode&0o022)!==0&&(stat.mode&0o1000)===0)throw new Error(`${label} ancestor is writable without sticky bit`);}}
export function validateRemoteProject(path:string){if(!isAbsolute(path)||path!==path.trim()||normalize(path)!==path||(path.length>1&&path.endsWith("/"))||/[\0\r\n]/.test(path))throw new Error("remote project must be a clean absolute path");}
async function validateProject(path:string){validateRemoteProject(path);const stat=await lstat(path);if(!stat.isDirectory())throw new Error("project must be an existing directory");}
function validateAgentID(value:string){if(!/^[A-Za-z0-9_-]{1,64}$/.test(value))throw new Error("agent id is invalid");}
function validateNodeIdentity(value:string){if(!/^[A-Za-z0-9_-]{1,64}$/.test(value))throw new Error("node identity is invalid");}
function validateDisplayMetadata(value:string,label:string,max:number){const trimmed=value.trim();if(!trimmed||trimmed.length>max||/[\0\r\n\t]/.test(trimmed))throw new Error(`${label} metadata is invalid`);}
function safePeerText(value:unknown,max:number):string|undefined{if(typeof value!=="string")return undefined;const clean=value.replace(/[\0\r\n\t\u001b\u202a-\u202e\u2066-\u2069]/g," ").replace(/\s+/g," ").trim();return clean?clean.slice(0,max):undefined;}
function titleCaseAllCaps(value:string):string{return /^[A-Z][A-Z\s-]+$/.test(value)?value.toLowerCase().replace(/\b\w/g,(letter)=>letter.toUpperCase()):value;}
function naturalPeerText(value:unknown,max:number):string|undefined{const clean=safePeerText(value,max);return clean?titleCaseAllCaps(clean):undefined;}
function naturalRoleText(value:unknown,max:number):string|undefined{const clean=safePeerText(value,max);return clean?titleCaseAllCaps(clean).toLowerCase():undefined;}
function isGenericRole(value:string|undefined):boolean{return !value||/^(actor|worker|selected recipient|unknown)$/i.test(value);}
function required<T>(value:T|undefined):T{if(!value)throw new Error("client is not ready");return value;}
async function parseFrame(data:unknown):Promise<Uint8Array>{const raw=data instanceof ArrayBuffer?new Uint8Array(data):data instanceof Blob?new Uint8Array(await data.arrayBuffer()):Buffer.isBuffer(data)?new Uint8Array(data):undefined;if(!raw||raw.byteLength<4)throw new Error("client response frame bound violated");const view=Buffer.from(raw.buffer,raw.byteOffset,raw.byteLength);const length=view.readUInt32BE(0);if(!length||length>MAX_FRAME||view.byteLength<length+4)throw new Error("client response frame bound violated");return view.subarray(4,length+4);}
