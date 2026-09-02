import { modelResultContent, naturalResultSummary, renderToolCall, renderToolResult } from "./widgets/tool-renderers.ts";

export function publicAgentView(agent:any){return {agentId:agent.agentId,displayName:agent.displayName,role:agent.role,state:agent.hostedPiRuntime?.state??0,bridgeReady:Boolean(agent.hostedPiRuntime?.bridgeReady),cleanupPending:Boolean(agent.hostedPiRuntime?.cleanupPending)};}

export type ClientOperations = {
  connect(target:string):Promise<unknown>;
  create(agentId:string,projectDirectory:string,displayName?:string,role?:string,nodeIdentity?:string):Promise<unknown>;
  list():Promise<unknown>;
  send(agentId:string,message:string,options?:{appendConversation?:boolean}):Promise<unknown>;
  ask(agentId:string,prompt:string,options?:{appendConversation?:boolean}):Promise<unknown>;
  status(agentId:string):Promise<unknown>;
  health(agentId:string):Promise<unknown>;
  attach(agentId:string):Promise<unknown>;
  stop(agentId:string):Promise<unknown>;
  subscribe(agentId:string):Promise<unknown>;
  unsubscribe(agentId:string):Promise<unknown>;
  resolve(target:string):Promise<unknown>;
  control(agentId:string,intent:number):Promise<unknown>;
};
type API={registerCommand(name:string,value:{description:string;handler(args:string,ctx:any):Promise<void>}):void;registerTool(value:{name:string;label:string;description:string;parameters:unknown;execute(id:string,params:any):Promise<any>;renderCall?(args:any,theme:any,context:any):unknown;renderResult?(result:any,options:any,theme:any,context:any):unknown}):void};
export function parsePair(args:string):[string,string]{const marker=args.indexOf(" -- ");if(marker<1)throw new Error("expected: actor -- value");const actor=args.slice(0,marker).trim(),value=args.slice(marker+4).trim();if(!actor||!value)throw new Error("actor and value are required");return[actor,value];}
export function parseCreateArgs(args:string):[string,string,string?,string?,string?]{const parts=args.split(" -- ").map((part)=>part.trim());if(parts.length<2||parts.length>5||!parts[0]||!parts[1])throw new Error("expected: actor -- /absolute/worktree [-- display name] [-- dynamic role] [-- node identity]");return[parts[0],parts[1],parts[2]||undefined,parts[3]||undefined,parts[4]||undefined];}
export function registerClientHandlers(api:API,operations:ClientOperations,schemas:{empty:unknown;target:unknown;actorTarget:unknown;actorTask:unknown;create:unknown}){
 const notify=(ctx:any,name:string,value:unknown)=>ctx.ui.notify(naturalResultSummary(name,value),"info");
 api.registerCommand("actor-connect",{description:"Connect actor tools to a workstation actor endpoint: [node|host|ws://host:port/actors]",handler:async(args,ctx)=>notify(ctx,"actor_connect",await operations.connect(args))});
 api.registerCommand("actor-create",{description:"Create a hosted actor: name -- /absolute/worktree [-- display name] [-- dynamic role] [-- node identity]",handler:async(args,ctx)=>{const[a,p,d,r,n]=parseCreateArgs(args);notify(ctx,"actor_create",await operations.create(a,p,d,r,n));}});
 api.registerCommand("actor-list",{description:"List authorized logical actors",handler:async(_args,ctx)=>notify(ctx,"actor_list",await operations.list())});
 api.registerCommand("actor-resolve",{description:"Resolve a logical actor",handler:async(args,ctx)=>notify(ctx,"actor_resolve",await operations.resolve(args.trim()))});
 api.registerCommand("actor-tell",{description:"Tell an actor asynchronously: actor -- message",handler:async(args,ctx)=>{const[a,p]=parsePair(args);notify(ctx,"actor_tell",await operations.send(a,p));}});
 api.registerCommand("actor-ask",{description:"Ask an actor and wait for completion: actor -- prompt",handler:async(args,ctx)=>{const[a,p]=parsePair(args);notify(ctx,"actor_ask",await operations.ask(a,p));}});
 api.registerCommand("actor-health",{description:"Ping an actor and show reachability details",handler:async(args,ctx)=>notify(ctx,"actor_health",await operations.health(args.trim()))});
 api.registerCommand("actor-stop",{description:"Stop an exactly owned actor",handler:async(args,ctx)=>notify(ctx,"actor_stop",await operations.stop(args.trim()))});
 api.registerCommand("actor-abort",{description:"Abort an exactly owned hosted actor",handler:async(args,ctx)=>notify(ctx,"actor_abort",await operations.control(args.trim(),1))});
 api.registerCommand("actor-shutdown",{description:"Shutdown an exactly owned hosted actor",handler:async(args,ctx)=>notify(ctx,"actor_shutdown",await operations.control(args.trim(),2))});
 api.registerCommand("actor-subscribe",{description:"Subscribe to actor events",handler:async(args,ctx)=>notify(ctx,"actor_subscribe",await operations.subscribe(args.trim()))});
 api.registerCommand("actor-unsubscribe",{description:"Unsubscribe from actor events",handler:async(args,ctx)=>notify(ctx,"actor_unsubscribe",await operations.unsubscribe(args.trim()))});
 const tool=(name:string,description:string,parameters:unknown,run:(p:any)=>Promise<unknown>)=>api.registerTool({name,label:name,description,parameters,async execute(_id,p){const result=await run(p);return{content:[{type:"text",text:modelResultContent(name,result)}],details:result};},renderCall(args,theme,context){return renderToolCall(name,args,theme);},renderResult(result,options,theme,context){return renderToolResult(name,result,options,theme);}});
 tool("actor_create","Create a named global hosted actor with optional display_name, dynamic role metadata, and logical node_identity",schemas.create,p=>operations.create(p.agentId,p.projectDirectory,p.displayName,p.role,p.nodeIdentity));tool("actor_list","List authorized logical actors",schemas.empty,()=>operations.list());tool("actor_resolve","Resolve a logical actor",schemas.actorTarget,p=>operations.resolve(p.target));tool("actor_tell","Tell a logical actor asynchronously",schemas.actorTask,p=>operations.send(p.target,p.message,{appendConversation:false}));tool("actor_ask","Ask a logical actor and wait for its completion",schemas.actorTask,p=>operations.ask(p.target,p.message,{appendConversation:false}));tool("actor_health","Ping actor reachability and details",schemas.actorTarget,p=>operations.health(p.target));tool("actor_stop","Stop an exactly owned actor",schemas.actorTarget,p=>operations.stop(p.target));tool("actor_abort","Abort a hosted actor",schemas.actorTarget,p=>operations.control(p.target,1));tool("actor_shutdown","Shutdown a hosted actor",schemas.actorTarget,p=>operations.control(p.target,2));tool("actor_subscribe","Subscribe to bounded events",schemas.actorTarget,p=>operations.subscribe(p.target));tool("actor_unsubscribe","Unsubscribe from actor events",schemas.actorTarget,p=>operations.unsubscribe(p.target));
}
