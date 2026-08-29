import test from "node:test";
import assert from "node:assert/strict";
import { publicAgentView, registerClientHandlers } from "../../home/dot_pi/private_agent/extensions/actor-client/handlers.ts";
import { ActorClientConversationLog, actorAskCompletionContent, initialActorClientRosterState, reduceActorClientRoster, validateRemoteProject } from "../../home/dot_pi/private_agent/extensions/actor-client/index.ts";
import { outgoingExchange } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/communication-ui.ts";

test("remote project validation is syntax-only and does not require a local path", () => {
  assert.doesNotThrow(() => validateRemoteProject("/root/lazyvim"));
  for (const invalid of ["root/lazyvim", "/root/../tmp", "/root/lazyvim/", " /root/lazyvim", "/root/lazyvim\n"]) assert.throws(() => validateRemoteProject(invalid), /clean absolute path/);
});

test("actor-client public views use display metadata and suppress raw runtime internals", () => {
  const view = publicAgentView({agentId:"agent-42",displayName:"Release Reviewer",role:"Review Lead",hostedPiRuntime:{state:3,bridgeReady:true,cleanupPending:false,runtimeId:"raw-runtime",tmuxSessionId:"$1",tmuxSession:"raw",panePid:123,piSessionName:"hosted-raw"}});
  assert.deepEqual(view,{agentId:"agent-42",displayName:"Release Reviewer",role:"Review Lead",state:3,bridgeReady:true,cleanupPending:false});
  const encoded = JSON.stringify(view);
  for (const forbidden of ["raw-runtime","tmux","panePid","123","hosted-raw","attachTarget","sessionId","handle","fence"]) assert.doesNotMatch(encoded,new RegExp(forbidden,"i"));
});

test("actor-client roster reducer fences frames and renders redacted lifecycle", () => {
  let state = initialActorClientRosterState();
  state = reduceActorClientRoster(state, { type: "CONNECTED" });
  state = reduceActorClientRoster(state, { type: "ROSTER_FRAME", frame: { operation: 2, epoch: 10n, sequence: 1n } });
  state = reduceActorClientRoster(state, { type: "ROSTER_FRAME", frame: { operation: 3, epoch: 10n, sequence: 2n, status: "ready\n\u001b[31m", agentId: "alpha", agent: { agentId: "alpha", displayName: "Alpha\nReviewer", role: "QA", lifecycleRevision: 7n } } });
  assert.match(state.render, /^actors Alpha Reviewer:\[redacted\] ready/);
  assert.doesNotMatch(state.render, /\u001b|working|idle|tmux|pid/i);
  const fenced = reduceActorClientRoster(state, { type: "ROSTER_FRAME", frame: { operation: 4, epoch: 9n, sequence: 99n, agentId: "alpha" } });
  assert.equal(fenced.agents.has("alpha"), true);
  state = reduceActorClientRoster(state, { type: "ROSTER_FRAME", frame: { operation: 4, epoch: 10n, sequence: 3n, agentId: "alpha" } });
  assert.equal(state.agents.size, 0);
});

test("actor ask reply sends one model-visible custom message and clears pending", async () => {
  const entries=[],messages=[],statuses=[];
  const log = new ActorClientConversationLog({ appendEntry: (_type, data) => entries.push(data), sendMessage: (message, options) => messages.push({ message, options }) }, (count) => statuses.push(count));
  assert.equal(log.recordAskPending({ key: "actor-client:request-1", requestId: "request-1", dedupeId: "dedupe-1", chainId: "chain-1", sourceMutationSequence: "7", source: "Project Manager", target: "Reviewer", kind: "Ask", prompt: "question" }), true);
  assert.equal(log.recordAskPending({ key: "actor-client:request-1", requestId: "request-1", dedupeId: "dedupe-1", chainId: "chain-1", sourceMutationSequence: "7", prompt: "question", kind: "Ask" }), false);
  assert.equal(await log.complete({ key: "actor-client:request-1", reply: "complete answer\nwith all details", completed: true, requestId: "request-1", dedupeId: "dedupe-1", chainId: "chain-1", sourceMutationSequence: "7", source: { displayName: "Project Manager", authoritative: true }, target: { displayName: "Reviewer", authoritative: true }, kind: "Ask" }), true);
  assert.equal(await log.complete({ key: "actor-client:request-1", reply: "duplicate", completed: true }), false);
  assert.equal(entries.length, 1);
  assert.equal(messages.length, 1);
  assert.deepEqual(messages[0].options, { deliverAs: "followUp", triggerTurn: true });
  assert.equal(messages[0].message.customType, "actor-client-ask-completion");
  assert.equal(messages[0].message.display, true);
  assert.match(messages[0].message.content, /requestId=request-1/);
  assert.match(messages[0].message.content, /dedupeId=dedupe-1/);
  assert.match(messages[0].message.content, /chainId=chain-1/);
  assert.match(messages[0].message.content, /sourceMutationSequence=7/);
  assert.match(messages[0].message.content, /source=Project Manager/);
  assert.match(messages[0].message.content, /sourceAuthoritative=true/);
  assert.match(messages[0].message.content, /target=Reviewer/);
  assert.match(messages[0].message.content, /targetAuthoritative=true/);
  assert.match(messages[0].message.content, /kind=Ask/);
  assert.match(messages[0].message.content, /terminal=replied/);
  assert.match(messages[0].message.content, /nextAction=continue/);
  assert.match(messages[0].message.content, /complete answer\nwith all details/);
  assert.equal(messages[0].message.details.answer, "complete answer\nwith all details");
  assert.deepEqual(messages[0].message.details.sourcePeer, { displayName: "Project Manager", authoritative: true });
  assert.deepEqual(messages[0].message.details.targetPeer, { displayName: "Reviewer", authoritative: true });
  assert.equal(actorAskCompletionContent(messages[0].message.details), messages[0].message.content);
  assert.equal(messages[0].message.details.communicationView.state, "replied");
  assert.deepEqual(statuses, [1, 0]);
});

test("actor ask completion dedupes concurrent pushes and replay restored from custom messages", async () => {
  const concurrent=[];
  const delayed = new ActorClientConversationLog({ appendEntry: () => {}, sendMessage: async (message) => { concurrent.push(message); await new Promise((resolve) => setTimeout(resolve, 10)); } });
  await Promise.all([delayed.complete({ key: "actor-client:request-race", reply: "first", completed: true }), delayed.complete({ key: "actor-client:request-race", reply: "second", completed: true })]);
  assert.equal(concurrent.length, 1);
  assert.equal(concurrent[0].details.answer, "first");
  const messages=[],statuses=[];
  const log = new ActorClientConversationLog({ appendEntry: () => {}, sendMessage: (message) => messages.push(message) }, (count) => statuses.push(count));
  log.restore([{ type: "custom", customType: "actor-client-ask-pending", data: { key: "actor-client:request-2", requestId: "request-2", dedupeId: "dedupe-2", chainId: "chain-2", sourceMutationSequence: "8", prompt: "question", kind: "Ask" } }, { type: "custom", customType: "actor-client-ask-completion", details: { key: "actor-client:request-2" } }]);
  assert.equal(await log.complete({ key: "actor-client:request-2", reply: "replayed", completed: true }), false);
  assert.equal(messages.length, 0);
  assert.equal(statuses.at(-1), 0);
});

test("actor ask failure completion preserves metadata and next action", async () => {
  const messages=[];
  const log = new ActorClientConversationLog({ appendEntry: () => {}, sendMessage: (message) => messages.push(message) });
  await log.complete({ key: "actor-client:request-3", reply: "", completed: false, reason: "target failed", requestId: "request-3", dedupeId: "dedupe-3", chainId: "chain-3", sourceMutationSequence: "9", kind: "Ask" });
  assert.equal(messages.length, 1);
  assert.match(messages[0].content, /terminal=failed/);
  assert.match(messages[0].content, /reason=target failed/);
  assert.match(messages[0].content, /nextAction=retry or choose another actor/);
  assert.equal(messages[0].details.communicationView.state, "failed");
});

test("regular client Pi callbacks register noncolliding commands and tools", async () => {
  const commands=new Map(),tools=new Map(),calls=[];
  const api={registerCommand:(name,value)=>commands.set(name,value),registerTool:(value)=>tools.set(value.name,value)};
  const operations={connect:async(target)=>(calls.push(["connect",target]),{accepted:true,target}),create:async(a,p,d,r,n)=>(calls.push(["create",a,p,d,r,n]),{a,p,d,r,n}),list:async()=>(calls.push(["list"]),["a","b"]),send:async(a,p)=>(calls.push(["send",a,p]),{accepted:true,completed:true,target:"Release Reviewer",kind:"Tell",requestId:"request-send",dedupeId:"dedupe-send",chainId:"chain-send",sourceMutationSequence:"1",communicationView:outgoingExchange({key:"request-send",target:"Release Reviewer",body:p,accepted:true,completed:true,mode:"tell"})}),ask:async(a,p)=>(calls.push(["ask",a,p]),{accepted:true,completed:false,awaitingReply:true,target:"Release Reviewer",kind:"Ask",requestId:"request-ask",dedupeId:"dedupe-ask",chainId:"chain-ask",sourceMutationSequence:"2",communicationView:outgoingExchange({key:"request-ask",target:"Release Reviewer",body:p,accepted:true,completed:false,mode:"ask"})}),status:async(a)=>(calls.push(["status",a]),{}),health:async(a)=>(calls.push(["health",a]),{reachable:true}),attach:async(a)=>(calls.push(["attach",a]),"tmux"),stop:async(a)=>(calls.push(["stop",a]),{}),subscribe:async(a)=>(calls.push(["subscribe",a]),{}),unsubscribe:async(a)=>(calls.push(["unsubscribe",a]),{}),control:async(a,intent)=>(calls.push(["control",a,intent]),{accepted:true,completed:true,kind:intent===1?"Abort":"Shutdown"})};
  registerClientHandlers(api,operations,{empty:{},target:{},actorTarget:{},actorTask:{},create:{}});
  assert.deepEqual([...commands.keys()],["actor-connect","actor-create","actor-list","actor-resolve","actor-tell","actor-health","actor-stop","actor-abort","actor-shutdown","actor-subscribe","actor-unsubscribe"]);
  assert.deepEqual([...tools.keys()],["actor_create","actor_list","actor_resolve","actor_tell","actor_health","actor_stop","actor_abort","actor_shutdown","actor_subscribe","actor_unsubscribe"]);
  const notices=[];
  const ctx={ui:{notify(message){notices.push(message);}}};
  const theme={fg:(_name,text)=>text,bg:(_name,text)=>text,bold:(text)=>text};
  await commands.get("actor-connect").handler("node-b",ctx);
  await commands.get("actor-create").handler("actor42 -- /tmp/worktree -- Release Reviewer -- Review Lead",ctx);
  const noticesAfterCreate=notices.length;
  await commands.get("actor-tell").handler("actor42 -- implement the task",ctx);
  assert.ok(notices.length>=noticesAfterCreate,"message commands may return async receipts");
  assert.equal(typeof tools.get("actor_tell").renderCall,"function");
  assert.equal(typeof tools.get("actor_tell").renderResult,"function");
  const directAskResult = await tools.get("actor_tell").execute("id",{target:"actor42",message:"direct task"});
  assert.match(directAskResult.content[0].text,/requestId=request-ask/);
  const askResult = await tools.get("actor_tell").execute("id",{target:"actor42",message:"next task"});
  assert.doesNotMatch(askResult.content[0].text,/^\s*[\[{]/,"tool content exposed raw JSON");
  assert.match(askResult.content[0].text,/requestId=request-ask/);
  assert.match(askResult.content[0].text,/dedupeId=dedupe-ask/);
  const tellResult = await tools.get("actor_tell").execute("id",{target:"actor42",message:"tool tell async"});
  assert.match(tellResult.content[0].text,/requestId=request-ask/);
  const healthResult = await tools.get("actor_health").execute("id",{target:"actor42"});
  assert.equal(healthResult.details.reachable,true);
  assert.ok(notices.every((notice)=>!/^\s*[\[{]/.test(notice)),"command notification exposed raw JSON");
  const abortResult = await tools.get("actor_abort").execute("id",{target:"actor42"});
  assert.equal(abortResult.details.kind,"Abort");
  const shutdownResult = await tools.get("actor_shutdown").execute("id",{target:"actor42"});
  assert.equal(shutdownResult.details.kind,"Shutdown");
  await tools.get("actor_create").execute("id",{agentId:"remote42",projectDirectory:"/tmp/worktree",displayName:"Remote",role:"QA",nodeIdentity:"node-b"});
  await tools.get("actor_subscribe").execute("id",{target:"actor42"});
  assert.deepEqual(calls,[ ["connect","node-b"], ["create","actor42","/tmp/worktree","Release Reviewer","Review Lead",undefined], ["ask","actor42","implement the task"], ["ask","actor42","direct task"], ["ask","actor42","next task"], ["ask","actor42","tool tell async"], ["health","actor42"], ["control","actor42",1], ["control","actor42",2], ["create","remote42","/tmp/worktree","Remote","QA","node-b"], ["subscribe","actor42"] ]);
});
