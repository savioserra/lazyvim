import { modelResultContent, naturalResultSummary, renderToolCall, renderToolResult } from "../hosted-pi-bridge/communication-ui.ts";

export function publicAgentView(agent:any){return {agentId:agent.agentId,displayName:agent.displayName,role:agent.role,state:agent.hostedPiRuntime?.state??0,bridgeReady:Boolean(agent.hostedPiRuntime?.bridgeReady),cleanupPending:Boolean(agent.hostedPiRuntime?.cleanupPending)};}

export type ClientOperations = {
  create(agentId:string,projectDirectory:string,displayName?:string,role?:string):Promise<unknown>;
  list():Promise<unknown>;
  send(agentId:string,message:string,options?:{appendConversation?:boolean}):Promise<unknown>;
  ask(agentId:string,prompt:string,options?:{appendConversation?:boolean}):Promise<unknown>;
  promptStart(agentId:string,prompt:string,options?:{appendConversation?:boolean}):Promise<unknown>;
  promptStatus(agentId:string,lifecycleId:string,waitMillis?:number,options?:{appendConversation?:boolean}):Promise<unknown>;
  promptWait(agentId:string,lifecycleId:string,waitMillis?:number,options?:{appendConversation?:boolean}):Promise<unknown>;
  status(agentId:string):Promise<unknown>;
  attach(agentId:string):Promise<unknown>;
  stop(agentId:string):Promise<unknown>;
  subscribe(agentId:string):Promise<unknown>;
};
type API={registerCommand(name:string,value:{description:string;handler(args:string,ctx:any):Promise<void>}):void;registerTool(value:{name:string;label:string;description:string;parameters:unknown;execute(id:string,params:any):Promise<any>;renderCall?(args:any,theme:any,context:any):unknown;renderResult?(result:any,options:any,theme:any,context:any):unknown}):void};
export function parsePair(args:string):[string,string]{const marker=args.indexOf(" -- ");if(marker<1)throw new Error("expected: actor -- value");const actor=args.slice(0,marker).trim(),value=args.slice(marker+4).trim();if(!actor||!value)throw new Error("actor and value are required");return[actor,value];}
export function parseCreateArgs(args:string):[string,string,string?,string?]{const parts=args.split(" -- ").map((part)=>part.trim());if(parts.length<2||parts.length>4||!parts[0]||!parts[1])throw new Error("expected: actor -- /absolute/worktree [-- display name] [-- dynamic role]");return[parts[0],parts[1],parts[2]||undefined,parts[3]||undefined];}
export function registerClientHandlers(api:API,operations:ClientOperations,schemas:{empty:unknown;target:unknown;task:unknown;lifecycle:unknown;create:unknown}){
 const notify=(ctx:any,name:string,value:unknown)=>ctx.ui.notify(naturalResultSummary(name,value),"info");
 api.registerCommand("actor-client-create",{description:"Create a client actor: name -- /absolute/worktree [-- display name] [-- dynamic role]",handler:async(args,ctx)=>{const[a,p,d,r]=parseCreateArgs(args);notify(ctx,"actor_client_create",await operations.create(a,p,d,r));}});
 api.registerCommand("actor-client-list",{description:"List owned client actors",handler:async(_args,ctx)=>notify(ctx,"actor_client_list",await operations.list())});
 api.registerCommand("actor-client-send",{description:"Send a typed notification: actor -- message",handler:async(args,_ctx)=>{const[a,p]=parsePair(args);await operations.send(a,p);}});
 api.registerCommand("actor-client-ask",{description:"Run a real model task: actor -- prompt",handler:async(args,_ctx)=>{const[a,p]=parsePair(args);await operations.ask(a,p);}});
 api.registerCommand("actor-client-prompt-start",{description:"Start an observed model task: actor -- prompt",handler:async(args,_ctx)=>{const[a,p]=parsePair(args);await operations.promptStart(a,p);}});
 api.registerCommand("actor-client-prompt-status",{description:"Read observed task status: actor -- lifecycle-id",handler:async(args,_ctx)=>{const[a,p]=parsePair(args);await operations.promptStatus(a,p);}});
 api.registerCommand("actor-client-prompt-wait",{description:"Wait briefly for observed task completion: actor -- lifecycle-id",handler:async(args,_ctx)=>{const[a,p]=parsePair(args);await operations.promptWait(a,p);}});
 api.registerCommand("actor-client-status",{description:"Show actor status",handler:async(args,ctx)=>notify(ctx,"actor_client_status",await operations.status(args.trim()))});
 api.registerCommand("actor-client-attach",{description:"Print exact tmux attach command",handler:async(args,ctx)=>notify(ctx,"actor_client_attach",await operations.attach(args.trim()))});
 api.registerCommand("actor-client-stop",{description:"Stop an exactly owned actor",handler:async(args,ctx)=>notify(ctx,"actor_client_stop",await operations.stop(args.trim()))});
 const tool=(name:string,description:string,parameters:unknown,run:(p:any)=>Promise<unknown>)=>api.registerTool({name,label:name,description,parameters,async execute(_id,p){const result=await run(p);return{content:[{type:"text",text:modelResultContent(name,result)}],details:result};},renderCall(args,theme,context){return renderToolCall(name,args,theme);},renderResult(result,options,theme,context){return renderToolResult(name,result,options,theme);}});
 tool("actor_client_create","Create a named global hosted actor with optional display_name and dynamic role metadata",schemas.create,p=>operations.create(p.agentId,p.projectDirectory,p.displayName,p.role));tool("actor_client_list","List global actors",schemas.empty,()=>operations.list());tool("actor_client_send","Send a typed asynchronous notification",schemas.task,p=>operations.send(p.agentId,p.prompt,{appendConversation:false}));tool("actor_client_ask","Run a correlated model task",schemas.task,p=>operations.ask(p.agentId,p.prompt,{appendConversation:false}));tool("actor_client_prompt_start","Start a bounded observed model task",schemas.task,p=>operations.promptStart(p.agentId,p.prompt,{appendConversation:false}));tool("actor_client_prompt_status","Read observed model task lifecycle",schemas.lifecycle,p=>operations.promptStatus(p.agentId,p.lifecycleId,p.waitMillis,{appendConversation:false}));tool("actor_client_prompt_wait","Wait for observed model task lifecycle",schemas.lifecycle,p=>operations.promptWait(p.agentId,p.lifecycleId,p.waitMillis,{appendConversation:false}));tool("actor_client_status","Read actor status",schemas.target,p=>operations.status(p.agentId));tool("actor_client_attach","Return the tmux attach command",schemas.target,p=>operations.attach(p.agentId));tool("actor_client_stop","Stop an exactly owned actor",schemas.target,p=>operations.stop(p.agentId));tool("actor_client_subscribe","Subscribe to actor events",schemas.target,p=>operations.subscribe(p.agentId));
}
