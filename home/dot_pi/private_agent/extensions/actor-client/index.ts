import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { create, fromBinary, toBinary, type DescMessage } from "@bufbuild/protobuf";
import { randomUUID } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { connect, type Socket } from "node:net";
import { dirname, isAbsolute, join } from "node:path";
import { Type } from "typebox";
type Envelope = any;
let EnvelopeSchema: DescMessage;
import { completeHostedEnvironment, ExactMutationSequencer, mutationScopeKey } from "../hosted-pi-bridge/handlers.ts";
import { legacyCommunicationLine, outgoingExchange, renderCommunicationCard, type CommunicationView } from "../hosted-pi-bridge/communication-ui.ts";
import { publicAgentView, registerClientHandlers } from "./handlers.ts";

const MAX_FRAME = 64 * 1024;
const MAX_TEXT = 16 * 1024;
const NORMAL_TIMEOUT = 5_000;
const PROMPT_TIMEOUT = 30 * 60_000;

type Session = { sessionId: string; generationId: string; caller: string; credential: Uint8Array };
type Fence = { handle: string; fence: bigint };
type CredentialFile = { credential_b64: string };
type CommunicationEntry = { key: string; line?: string; view?: CommunicationView };
type PeerMetadata = { stableId?: string; displayName: string; role?: string; authoritative: boolean };

export class ActorClientConversationLog {
  private readonly seen = new Set<string>();
  private readonly pi: { appendEntry<T>(customType: string, data: T): void };
  constructor(pi: { appendEntry<T>(customType: string, data: T): void }) { this.pi = pi; }
  restore(entries: Array<{ type?: string; customType?: string; data?: Partial<CommunicationEntry> }>) {
    for (const entry of entries) if (entry.type === "custom" && entry.customType === "actor-client-communication" && typeof entry.data?.key === "string") this.seen.add(entry.data.key);
  }
  append(view: CommunicationView): boolean {
    if (this.seen.has(view.key)) return false;
    this.seen.add(view.key);
    this.pi.appendEntry<CommunicationEntry>("actor-client-communication", { key: view.key, line: legacyCommunicationLine(view), view });
    return true;
  }
}

export function actorClientPendingStatus(peer: { displayName?: string; authoritative?: boolean }): string {
  const displayName = naturalPeerText(peer.displayName, 80);
  if (!peer.authoritative || !displayName || isGenericRole(displayName)) throw new Error("authoritative actor display metadata is required before showing lifecycle status");
  return `◌ Waiting for ${displayName}…`;
}

export class ActorClientLifecycleConversation {
  private readonly bodies = new Map<string, string>();
  private readonly log: ActorClientConversationLog;
  constructor(log: ActorClientConversationLog) { this.log = log; }
  remember(lifecycleId: string, body: string): void { if (lifecycleId && body && !this.bodies.has(lifecycleId)) this.bodies.set(lifecycleId, body); }
  body(lifecycleId: string): string { return this.bodies.get(lifecycleId) ?? "Observed actor request."; }
  publish(view: CommunicationView, terminal: boolean): boolean { return terminal ? this.log.append(view) : false; }
}

class Client {
  private socket?: Socket;
  private sequence = 0n;
  private tail = Promise.resolve();
  private readonly path: string;
  private session: Session;

  constructor(path: string, session: Session) {
    this.path = path;
    this.session = session;
  }
  setSession(session: Session) { this.session = session; }
  async open() {
    await validatePrivateSocket(this.path);
    this.socket = await new Promise<Socket>((resolve, reject) => {
      const socket = connect(this.path);
      const timer = setTimeout(() => socket.destroy(new Error("client daemon connection timeout")), NORMAL_TIMEOUT);
      socket.once("connect", () => { clearTimeout(timer); resolve(socket); });
      socket.once("error", (error) => { clearTimeout(timer); reject(error); });
    });
  }
  async close() { const socket = this.socket;this.socket=undefined;if(!socket)return;socket.destroy();await new Promise<void>((resolve)=>socket.once("close",()=>resolve())); }
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
    try { socket.write(frame);const response=fromBinary(EnvelopeSchema,await readFrame(socket,timeout));if(response.sequence!==this.sequence||response.requestId!==envelope.requestId)throw new Error("client response correlation mismatch");if(response.payload.case==="protocolError")throw new Error(response.payload.value.message||"client request rejected");return response; }
    catch(error){if(this.socket===socket){this.socket=undefined;socket.destroy();}throw error;}
  }
}

export default async function wsActorClient(pi: ExtensionAPI) {
  // A hosted aggregate uses the hosted bridge's canonical actor tools. The
  // regular client must remain inert there or duplicate global discovery would
  // collide with the hosted tool surface.
  if (completeHostedEnvironment(process.env)) return;
  const discovered=discoverManagedPaths();
  const proto = await import("./subagents_pb.ts");
  const { ActorControlRequestSchema, ActorMessageRequestSchema, ActorMessageRequest_Mode, AttachRequestSchema, ClientSessionRequestSchema, ClientSessionRequest_Operation, HostedAdminRequestSchema, HostedAdminRequest_Operation, ListAgentsRequestSchema, PromptTaskRequestSchema, ResolveAgentRequestSchema, SubscribeAgentRequestSchema, TaskLifecycleRequestSchema, TaskLifecycleRequest_Operation, UnsubscribeAgentRequestSchema } = proto;
  EnvelopeSchema = proto.EnvelopeSchema;
  let admin:Client|undefined;let regular:Client|undefined;let session:Session|undefined;let context:ExtensionContext|undefined;
  const fences=new Map<string,Fence>();const peerCache=new Map<string,PeerMetadata>();let sourcePeer:PeerMetadata|undefined;const mutations=new ExactMutationSequencer();
  const adminSession:Session={sessionId:"",generationId:"",caller:"client-bootstrap",credential:new Uint8Array()};

  pi.registerEntryRenderer<CommunicationEntry>("actor-client-communication", (entry, _options, theme) => entry.data?.view ? renderCommunicationCard(entry.data.view, theme) : { render: () => [entry.data?.line ?? "actor communication unavailable"], invalidate() {} });
  const conversation = new ActorClientConversationLog(pi);
  const lifecycleConversation = new ActorClientLifecycleConversation(conversation);

  const createActor=async(agentId:string,projectDirectory:string,displayName?:string,role?:string,nodeIdentity?:string)=>{
    validateAgentID(agentId);await validateProject(projectDirectory);if(displayName!==undefined)validateDisplayMetadata(displayName,"display name",80);if(role!==undefined)validateDisplayMetadata(role,"role",64);if(nodeIdentity!==undefined)validateNodeIdentity(nodeIdentity);
    const response=await required(admin).request("hostedAdminRequest",HostedAdminRequestSchema,{operation:HostedAdminRequest_Operation.START,agentId,projectDirectory,trustProject:true,displayName:displayName?.trim()??"",role:role?.trim()??"",targetNode:nodeIdentity?.trim()??""},{timeout:30_000});
    if(response.payload.case!=="hostedAdminResponse")throw new Error("unexpected actor create response");
    return {accepted:response.payload.value.accepted,agentId:response.payload.value.agentId,reason:response.payload.value.reason};
  };
  const cacheAuthoritativePeer=(key:string,peer:PeerMetadata|undefined)=>{if(peer?.authoritative)peerCache.set(key,peer);return peer;};
  const peerFromProto=(peer:any):PeerMetadata|undefined=>{const stable=safePeerText(peer?.stableId,128);const display=naturalPeerText(peer?.displayName,80);const role=naturalRoleText(peer?.role,64);if(!display||display===stable||isGenericRole(display))return undefined;return {stableId:stable,displayName:display,role,authoritative:true};};
  const peerFromAgent=(agent:any):PeerMetadata|undefined=>{const display=naturalPeerText(agent?.displayName,80);const role=naturalRoleText(agent?.role,64);if(!display||display===agent?.agentId||isGenericRole(display))return undefined;return {stableId:safePeerText(agent?.agentId,128),displayName:display,role,authoritative:true};};
  const cachePeer=(agent:any)=>{const view=publicAgentView(agent);cacheAuthoritativePeer(view.agentId,peerFromAgent(view));return view;};
  const list=async()=>{const response=await required(regular).request("listAgentsRequest",ListAgentsRequestSchema,{});if(response.payload.case!=="listAgentsResponse")throw new Error("unexpected actor list response");return response.payload.value.agents.map(cachePeer);};
  const resolve=async(target:string)=>{validateAgentID(target);const response=await required(regular).request("resolveAgentRequest",ResolveAgentRequestSchema,{target});if(response.payload.case!=="resolveAgentResponse")throw new Error("unexpected actor resolve response");return response.payload.value;};
  const status=async(agentId:string)=>{validateAgentID(agentId);const response=await required(regular).request("listAgentsRequest",ListAgentsRequestSchema,{});if(response.payload.case!=="listAgentsResponse")throw new Error("unexpected actor status response");const found=response.payload.value.agents.find((agent)=>agent.agentId===agentId);return found?cachePeer(found):{accepted:false,agentId,reason:"agent not found or access denied"};};
  const authoritativePeer=async(agentId:string)=>{const cached=peerCache.get(agentId);if(cached?.authoritative)return cached;const result=await status(agentId) as any;const resolved=peerFromAgent(result);if(resolved)return cacheAuthoritativePeer(agentId,resolved)!;throw new Error("authoritative actor display metadata is required before starting lifecycle status");};
  const lifecyclePeerCorrelation=(target:PeerMetadata)=>{const details:any={};if(sourcePeer?.authoritative){details.sourceStableId=sourcePeer.stableId;details.sourceDisplayName=sourcePeer.displayName;if(sourcePeer.role)details.sourceRole=sourcePeer.role;}if(target.authoritative){details.targetStableId=target.stableId;details.targetDisplayName=target.displayName;if(target.role)details.targetRole=target.role;}return details;};
  const stop=async(agentId:string)=>{validateAgentID(agentId);const response=await required(admin).request("hostedAdminRequest",HostedAdminRequestSchema,{operation:HostedAdminRequest_Operation.STOP,agentId},{timeout:30_000});if(response.payload.case!=="hostedAdminResponse")throw new Error("unexpected actor stop response");fences.delete(agentId);return {accepted:response.payload.value.accepted,agentId,state:response.payload.value.runtime?.state??0,reason:response.payload.value.reason};};
  const attach=async(agentId:string)=>{validateAgentID(agentId);const cached=fences.get(agentId);if(cached)return cached;const response=await required(regular).request("attachRequest",AttachRequestSchema,{agentId,requestedCapabilities:["observe","send","ask","prompt","control_abort","control_shutdown"]});if(response.payload.case!=="attachResponse"||!response.payload.value.agentHandle)throw new Error("actor attach rejected");const fence={handle:response.payload.value.agentHandle,fence:response.payload.value.fence};fences.set(agentId,fence);return fence;};
  const subscribe=async(agentId:string)=>{const fence=await attach(agentId);const response=await required(regular).request("subscribeAgentRequest",SubscribeAgentRequestSchema,{agentId,afterRevision:0n},{fence});if(response.payload.case!=="agentOperationResponse")throw new Error("unexpected subscribe response");return {completed:response.payload.value.completed,reason:response.payload.value.reason};};
  const unsubscribe=async(agentId:string)=>{const fence=await attach(agentId);const response=await required(regular).request("unsubscribeAgentRequest",UnsubscribeAgentRequestSchema,{agentId},{fence});if(response.payload.case!=="agentOperationResponse")throw new Error("unexpected unsubscribe response");return {completed:response.payload.value.completed,reason:response.payload.value.reason};};
  const control=async(agentId:string,intent:number)=>{validateAgentID(agentId);const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{intent,target:agentId,dedupeId:randomUUID(),chainId:randomUUID(),sourceMutationSequence,hopLimit:2}}),async(logical)=>{const response=await required(regular).request("actorControlRequest",ActorControlRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:NORMAL_TIMEOUT});if(response.payload.case!=="actorMessageResponse")throw new Error("unexpected actor control response");return {accepted:response.payload.value.accepted,completed:response.payload.value.completed,reason:response.payload.value.reason,kind:response.payload.value.kind,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence)};},async()=>required(regular).reopen());};
  const send=async(agentId:string,message:string,options:{appendConversation?:boolean}={})=>{validateAgentID(agentId);const text=message.trim();const encoded=new TextEncoder().encode(text);if(!encoded.byteLength||encoded.byteLength>MAX_TEXT)throw new Error("message must be non-empty and at most 16 KiB");const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{mode:ActorMessageRequest_Mode.TELL,target:agentId,boundedPayload:encoded,dedupeId:randomUUID(),chainId:randomUUID(),hopLimit:8,sourceMutationSequence}}),async(logical)=>{const started=Date.now();const response=await required(regular).request("actorMessageRequest",ActorMessageRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:NORMAL_TIMEOUT});if(response.payload.case!=="actorMessageResponse")throw new Error("unexpected actor message response");const value=response.payload.value;const targetPeer=peerFromProto(value.target)??await authoritativePeer(agentId);const protoSource=peerFromProto(value.source);if(protoSource)sourcePeer=protoSource;if(targetPeer.authoritative)cacheAuthoritativePeer(agentId,targetPeer);const view=outgoingExchange({key:`actor-client:${logical.requestId}`,target:targetPeer,body:text,accepted:value.accepted,completed:value.completed,mode:"tell",reason:value.reason,durationMillis:Date.now()-started});if(options.appendConversation!==false)conversation.append(view);return {accepted:value.accepted,completed:value.completed,reason:value.reason,source:protoSource?.displayName,target:targetPeer.authoritative?targetPeer.displayName:undefined,kind:value.kind,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence),communicationView:view};},async()=>required(regular).reopen());};
  const ask=async(agentId:string,prompt:string,options:{appendConversation?:boolean}={})=>{validateAgentID(agentId);const text=prompt.trim();const encoded=new TextEncoder().encode(text);if(!encoded.byteLength||encoded.byteLength>MAX_TEXT)throw new Error("prompt must be non-empty and at most 16 KiB");const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{target:agentId,boundedPrompt:encoded,dedupeId:randomUUID(),chainId:randomUUID(),hopLimit:8,sourceMutationSequence}}),async(logical)=>{const started=Date.now();const response=await required(regular).request("promptTaskRequest",PromptTaskRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:PROMPT_TIMEOUT});if(response.payload.case!=="promptTaskResponse")throw new Error("unexpected task prompt response");const answer=new TextDecoder("utf-8",{fatal:true}).decode(response.payload.value.boundedAnswer);const view=outgoingExchange({key:`actor-client:${logical.requestId}`,target:agentId,body:text,reply:answer,accepted:response.payload.value.accepted,completed:response.payload.value.completed,mode:"ask",reason:response.payload.value.reason,durationMillis:Date.now()-started});if(options.appendConversation!==false)conversation.append(view);return {accepted:response.payload.value.accepted,completed:response.payload.value.completed,answer,reason:response.payload.value.reason,requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence),communicationView:view};},async()=>required(regular).reopen());};
  const observePrompt=(value:any,correlation:any={})=>({accepted:value.accepted,lifecycleId:value.lifecycleId,state:value.state,terminal:value.terminal,answer:new TextDecoder("utf-8",{fatal:true}).decode(value.boundedAnswer),reason:value.reason,...correlation});
  const updateLifecycleStatus=(terminal:boolean,peer:PeerMetadata)=>{const ctx=context;if(!ctx)return;ctx.ui.setStatus("actor-client-lifecycle",terminal?undefined:actorClientPendingStatus(peer));};
  const promptStart=async(agentId:string,prompt:string,options:{appendConversation?:boolean}={})=>{validateAgentID(agentId);const text=prompt.trim();const encoded=new TextEncoder().encode(text);if(!encoded.byteLength||encoded.byteLength>MAX_TEXT)throw new Error("prompt must be non-empty and at most 16 KiB");const peer=await authoritativePeer(agentId);const fence=await attach(agentId);return mutations.run(mutationScopeKey(fence,0n),(sourceMutationSequence)=>({requestId:randomUUID(),value:{operation:TaskLifecycleRequest_Operation.START,lifecycleId:randomUUID(),target:agentId,boundedPrompt:encoded,dedupeId:randomUUID(),chainId:randomUUID(),hopLimit:8,sourceMutationSequence}}),async(logical)=>{const started=Date.now();const response=await required(regular).request("taskLifecycleRequest",TaskLifecycleRequestSchema,logical.value,{fence,requestId:logical.requestId,timeout:PROMPT_TIMEOUT});if(response.payload.case!=="taskLifecycleResponse")throw new Error("unexpected task lifecycle response");const observed=observePrompt(response.payload.value,{requestId:logical.requestId,dedupeId:logical.value.dedupeId,chainId:logical.value.chainId,sourceMutationSequence:String(logical.value.sourceMutationSequence),...lifecyclePeerCorrelation(peer)});lifecycleConversation.remember(observed.lifecycleId,text);const view=outgoingExchange({key:`actor-client:lifecycle:${observed.lifecycleId}`,target:peer,body:lifecycleConversation.body(observed.lifecycleId),reply:observed.answer,accepted:observed.accepted,completed:observed.terminal,mode:"ask",reason:observed.reason,durationMillis:Date.now()-started});updateLifecycleStatus(observed.terminal,peer);if(options.appendConversation!==false)lifecycleConversation.publish(view,Boolean(observed.terminal));return {...observed,communicationView:view};},async()=>required(regular).reopen());};
  const promptObserve=async(agentId:string,lifecycleId:string,waitMillis=0,options:{appendConversation?:boolean}={})=>{validateAgentID(agentId);validateLifecycleID(lifecycleId);const peer=await authoritativePeer(agentId);const fence=await attach(agentId);try{const started=Date.now();const response=await required(regular).request("taskLifecycleRequest",TaskLifecycleRequestSchema,{operation:waitMillis>0?TaskLifecycleRequest_Operation.WAIT:TaskLifecycleRequest_Operation.STATUS,lifecycleId,target:agentId,waitMillis},{fence,timeout:Math.min(Math.max(waitMillis + NORMAL_TIMEOUT, NORMAL_TIMEOUT), 35_000)});if(response.payload.case!=="taskLifecycleResponse")throw new Error("unexpected task lifecycle response");const observed=observePrompt(response.payload.value,lifecyclePeerCorrelation(peer));const view=outgoingExchange({key:`actor-client:lifecycle:${observed.lifecycleId}`,target:peer,body:lifecycleConversation.body(observed.lifecycleId),reply:observed.answer,accepted:observed.accepted,completed:observed.terminal,mode:"ask",reason:observed.reason,durationMillis:Date.now()-started});updateLifecycleStatus(observed.terminal,peer);if(options.appendConversation!==false)lifecycleConversation.publish(view,Boolean(observed.terminal));return {...observed,communicationView:view};}catch(error){await required(regular).reopen();throw error;}};
  const promptWait=async(agentId:string,lifecycleId:string,waitMillis=30_000,options:{appendConversation?:boolean}={})=>promptObserve(agentId,lifecycleId,waitMillis,options);
  const attachCommand=async(agentId:string)=>attach(agentId);

  const target=Type.Object({agentId:Type.String({minLength:1})});const actorTarget=Type.Object({target:Type.String({minLength:1})});const actorTask=Type.Object({target:Type.String({minLength:1}),message:Type.String({minLength:1,maxLength:MAX_TEXT})});const task=Type.Object({agentId:Type.String({minLength:1}),prompt:Type.String({minLength:1,maxLength:MAX_TEXT})});const lifecycle=Type.Object({agentId:Type.String({minLength:1}),lifecycleId:Type.String({minLength:1}),waitMillis:Type.Optional(Type.Number({minimum:0,maximum:30000}))});
  registerClientHandlers(pi as any,{create:createActor,list,resolve,send,ask,promptStart,promptStatus:promptObserve,promptWait,status,attach:attachCommand,stop,subscribe,unsubscribe,control},{empty:Type.Object({}),target,actorTarget,actorTask,task,lifecycle,create:Type.Object({agentId:Type.String({minLength:1}),projectDirectory:Type.String({minLength:1}),displayName:Type.Optional(Type.String({minLength:1,maxLength:80})),role:Type.Optional(Type.String({minLength:1,maxLength:64})),nodeIdentity:Type.Optional(Type.String({minLength:1,maxLength:64}))})});

  pi.on("session_start",async(_event,ctx)=>{context=ctx;conversation.restore(ctx.sessionManager.getEntries() as any);const paths=await waitForManagedPaths(discovered);const adminCredential=await loadCredential(paths.adminPath);adminSession.credential=adminCredential;admin=new Client(paths.socketPath,adminSession);await admin.open();const opened=await admin.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.OPEN});if(opened.payload.case!=="clientSessionResponse"||!opened.payload.value.accepted||opened.payload.value.sessionCredential.byteLength!==32)throw new Error("client session bootstrap rejected");session={sessionId:opened.payload.value.sessionId,generationId:opened.payload.value.generationId,caller:opened.payload.value.callerIdentity,credential:opened.payload.value.sessionCredential};sourcePeer=peerFromProto((opened.payload.value as any).clientPeer??(opened.payload.value as any).source??(opened.payload.value as any).peer);regular=new Client(paths.socketPath,session);await regular.open();ctx.ui.setStatus("actor-client","actors ready");});
  pi.on("session_shutdown",async(_event,ctx)=>{try{if(regular&&session)await regular.request("clientSessionRequest",ClientSessionRequestSchema,{operation:ClientSessionRequest_Operation.CLOSE});}catch{}await Promise.all([regular?.close(),admin?.close()]);regular=undefined;admin=undefined;session=undefined;fences.clear();peerCache.clear();sourcePeer=undefined;ctx.ui.setStatus("actor-client",undefined);context=undefined;});
}

function discoverManagedPaths(){const home=process.env.HOME;if(!home||!isAbsolute(home))throw new Error("HOME is required for managed actor discovery");const stateAdmin=join(home,".local/state/workstation/subagents/admin/credential.json");const pairs:{socketPath:string;adminPath:string}[]=[];if(process.env.XDG_RUNTIME_DIR){const runtime=join(process.env.XDG_RUNTIME_DIR,"ws-subagents");pairs.push({socketPath:join(runtime,"control.sock"),adminPath:join(runtime,"admin/credential.json")},{socketPath:join(runtime,"control.sock"),adminPath:stateAdmin});}pairs.push({socketPath:join(home,".local/state/workstation/runtime/ws-subagents/control.sock"),adminPath:stateAdmin});return pairs;}
async function waitForManagedPaths(discovered:{socketPath:string;adminPath:string}[]){const deadline=Date.now()+15_000;let last:unknown;while(Date.now()<deadline){for(const paths of discovered){try{await validatePrivateSocket(paths.socketPath);await validatePrivateFile(paths.adminPath,"admin credential file");return paths;}catch(error){last=error;}}await new Promise((resolve)=>setTimeout(resolve,250));}throw new Error(`managed actor service is not ready (${last instanceof Error?last.message:"unknown readiness failure"})`);}
async function loadCredential(path:string){await validatePrivateFile(path,"admin credential file");const parsed=JSON.parse(await readFile(path,"utf8")) as CredentialFile;const value=Uint8Array.from(Buffer.from(parsed.credential_b64,"base64"));if(value.byteLength!==32)throw new Error("admin credential has invalid length");return value;}
async function validatePrivateFile(path:string,label:string){if(!isAbsolute(path))throw new Error(`${label} path must be absolute`);await validateNoSymlinkAncestors(dirname(path),label);const stat=await lstat(path);const uid=typeof process.getuid==="function"?process.getuid():undefined;if(!stat.isFile()||(stat.mode&0o777)!==0o600||(uid!==undefined&&stat.uid!==uid))throw new Error(`${label} is not owner-private`);}
async function validatePrivateSocket(path:string){if(!isAbsolute(path))throw new Error("client socket path must be absolute");await validateNoSymlinkAncestors(dirname(path),"client socket directory");const[socket,parent]=await Promise.all([lstat(path),lstat(dirname(path))]);const uid=typeof process.getuid==="function"?process.getuid():undefined;if(!socket.isSocket()||(socket.mode&0o777)!==0o600||(uid!==undefined&&socket.uid!==uid))throw new Error("client daemon socket is not owner-private");if(!parent.isDirectory()||(parent.mode&0o077)!==0||(uid!==undefined&&parent.uid!==uid))throw new Error("client socket directory is not owner-private");}
async function validateNoSymlinkAncestors(path:string,label:string){const uid=typeof process.getuid==="function"?process.getuid():undefined;const parts=path.split("/").filter(Boolean);let current="";for(const part of parts){current+=`/${part}`;const stat=await lstat(current);if(stat.isSymbolicLink()||!stat.isDirectory())throw new Error(`${label} ancestor is unsafe`);if(uid!==undefined&&stat.uid!==uid&&stat.uid!==0)throw new Error(`${label} ancestor has foreign ownership`);if((stat.mode&0o022)!==0&&(stat.mode&0o1000)===0)throw new Error(`${label} ancestor is writable without sticky bit`);}}
async function validateProject(path:string){if(!isAbsolute(path)||path!==path.trim()||/[\0\r\n]/.test(path))throw new Error("project must be a clean absolute path");const stat=await lstat(path);if(!stat.isDirectory())throw new Error("project must be an existing directory");}
function validateAgentID(value:string){if(!/^[A-Za-z0-9_-]{1,64}$/.test(value))throw new Error("agent id is invalid");}
function validateNodeIdentity(value:string){if(!/^[A-Za-z0-9_-]{1,64}$/.test(value))throw new Error("node identity is invalid");}
function validateLifecycleID(value:string){if(!/^[A-Za-z0-9_.:-]{1,128}$/.test(value))throw new Error("task lifecycle id is invalid");}
function validateDisplayMetadata(value:string,label:string,max:number){const trimmed=value.trim();if(!trimmed||trimmed.length>max||/[\0\r\n\t]/.test(trimmed))throw new Error(`${label} metadata is invalid`);}
function safePeerText(value:unknown,max:number):string|undefined{if(typeof value!=="string")return undefined;const clean=value.replace(/[\0\r\n\t\u001b\u202a-\u202e\u2066-\u2069]/g," ").replace(/\s+/g," ").trim();return clean?clean.slice(0,max):undefined;}
function titleCaseAllCaps(value:string):string{return /^[A-Z][A-Z\s-]+$/.test(value)?value.toLowerCase().replace(/\b\w/g,(letter)=>letter.toUpperCase()):value;}
function naturalPeerText(value:unknown,max:number):string|undefined{const clean=safePeerText(value,max);return clean?titleCaseAllCaps(clean):undefined;}
function naturalRoleText(value:unknown,max:number):string|undefined{const clean=safePeerText(value,max);return clean?titleCaseAllCaps(clean).toLowerCase():undefined;}
function isGenericRole(value:string|undefined):boolean{return !value||/^(actor|worker|selected recipient|unknown)$/i.test(value);}
function required<T>(value:T|undefined):T{if(!value)throw new Error("client is not ready");return value;}
function readFrame(socket:Socket,timeout:number):Promise<Uint8Array>{return new Promise((resolve,reject)=>{let buffer=Buffer.alloc(0);const timer=setTimeout(()=>finish(new Error("client response timeout")),timeout);const finish=(error?:Error,value?:Uint8Array)=>{clearTimeout(timer);socket.off("data",onData);socket.off("error",onError);socket.off("close",onClose);error?reject(error):resolve(value!);};const onError=(error:Error)=>finish(error);const onClose=()=>finish(new Error("client daemon disconnected"));const onData=(chunk:Buffer)=>{buffer=Buffer.concat([buffer,chunk]);if(buffer.length<4)return;const length=buffer.readUInt32BE(0);if(!length||length>MAX_FRAME)return finish(new Error("client response frame bound violated"));if(buffer.length>=length+4)finish(undefined,buffer.subarray(4,length+4));};socket.on("data",onData);socket.once("error",onError);socket.once("close",onClose);});}
