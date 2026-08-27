import assert from "node:assert/strict";
import test from "node:test";
import { buildActorControl, buildActorMessage, buildDeliveryAck, communicationKey, communicationLine, CommunicationTimeline, completeHostedEnvironment, ExactMutationSequencer, PromptTaskCoordinator, deliveryAction, destroyOnFramingFailure, drainPages, executeTypedDelivery, invokeTypedDeliveryForAck, parseTargetMessage, registerHostedHandlers, requireExplicitModelTarget } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/handlers.ts";
import { incomingNote, incomingRequestText, outgoingExchange, renderCommunicationCard, compactToolCall, compactToolResult } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/communication-ui.ts";

const complete = { WS_SUBAGENTS_SOCKET: "/run/user/1000/socket", WS_SUBAGENTS_CREDENTIAL_FILE: "/state/credential", WS_SUBAGENTS_SESSION_ID: "session", WS_SUBAGENTS_GENERATION_ID: "generation", WS_SUBAGENTS_CALLER: "hosted:agent", WS_SUBAGENTS_AGENT_ID: "agent", WS_SUBAGENTS_RUNTIME_ID: "runtime", WS_SUBAGENTS_INCARNATION: "1" };

test("extension registration requires the complete hosted environment", () => {
  assert.equal(completeHostedEnvironment({}), false);
  assert.equal(completeHostedEnvironment({ WS_SUBAGENTS_RUNTIME_ID: "runtime" }), false);
  assert.equal(completeHostedEnvironment({ ...complete, WS_SUBAGENTS_INCARNATION: "0" }), false);
  assert.equal(completeHostedEnvironment(complete), true);
});

test("human command parsing and model target policy are distinct", () => {
  assert.deepEqual(parseTargetMessage("agent -- hello"), ["agent", "hello"]);
  assert.deepEqual(parseTargetMessage("hello self"), [undefined, "hello self"]);
  assert.throws(() => requireExplicitModelTarget(undefined), /explicit target/);
  assert.equal(requireExplicitModelTarget(" agent "), "agent");
});

test("every framing failure destroys the stream before another request", async () => {
  for (const failure of ["timeout", "malformed", "close", "correlation"]) {
    let destroyed = false;
    await assert.rejects(() => destroyOnFramingFailure({ destroy() { destroyed = true; } }, async () => { throw new Error(failure); }), new RegExp(failure));
    assert.equal(destroyed, true, `${failure} left a desynchronized stream open`);
  }
});

test("pagination drains every page and advances only through emitted cursors", async () => {
  const pages = [{ latestSequence: 64n, more: true, values: 64 }, { latestSequence: 128n, more: true, values: 64 }, { latestSequence: 130n, more: false, values: 2 }];
  let consumed = 0;
  const cursor = await drainPages(0n, async () => pages.shift(), async (page) => { consumed += page.values; });
  assert.equal(cursor, 130n); assert.equal(consumed, 130);
  await assert.rejects(() => drainPages(5n, async () => ({ latestSequence: 5n, more: true }), async () => {}), /did not advance/);
});

test("actual registered command and tool callbacks invoke every hosted operation", async () => {
  const commands = new Map(), tools = new Map(), calls = [];
  const api = { registerCommand(name, registration) { commands.set(name, registration); }, registerTool(registration) { tools.set(registration.name, registration); } };
  const operations = {
    async list() { calls.push(["list"]); return { ok: true }; }, async resolve(target) { calls.push(["resolve", target]); return {}; },
    async message(mode, target, text) { calls.push(["message", mode, target, text]); return { accepted: true, completed: mode === 2 }; },
    async control(intent, target) { calls.push(["control", intent, target]); return { accepted: true }; },
    async subscribe(target) { calls.push(["subscribe", target]); return { completed: true }; }, async unsubscribe(target) { calls.push(["unsubscribe", target]); return { completed: true }; },
  };
  registerHostedHandlers(api, operations, { empty: {}, target: {}, modelTarget: {}, message: {} });
  const notices = [];
  const context = { ui: { notify(message) { notices.push(message); } } };
  await commands.get("actor-list").handler("", context); await commands.get("actor-resolve").handler("", context);
  const beforeMessageNotices = notices.length;
  await commands.get("actor-send").handler(" -- human self", context); await commands.get("actor-ask").handler("target -- question", context);
  assert.equal(notices.length, beforeMessageNotices, "command-driven message exchanges are rendered as cards, not duplicate popups");
  await commands.get("actor-abort").handler("target", context); await commands.get("actor-shutdown").handler("target", context);
  await commands.get("actor-subscribe").handler("target", context); await commands.get("actor-unsubscribe").handler("target", context);
  for (const [name, params] of [["actor_list", {}], ["actor_resolve", { target: "target" }], ["actor_send", { target: "target", message: "tell" }], ["actor_ask", { target: "target", message: "ask" }], ["actor_abort", { target: "target" }], ["actor_shutdown", { target: "target" }], ["actor_subscribe", { target: "target" }], ["actor_unsubscribe", { target: "target" }]]) {
    const registration = tools.get(name);
    const result = await registration.execute("id", params);
    assert.equal(typeof registration.renderCall, "function");
    assert.equal(typeof registration.renderResult, "function");
    assert.doesNotMatch(result.content[0].text, /^\s*[\[{]/, `${name} exposed raw JSON as tool content`);
  }
  await assert.rejects(() => tools.get("actor_send").execute("id", { message: "implicit" }), /explicit target/);
  assert.equal(commands.size, 8); assert.equal(tools.size, 8);
  assert.ok(calls.some((call) => call[0] === "message" && call[1] === 1 && call[2] === undefined));
  assert.ok(calls.some((call) => call[0] === "message" && call[1] === 2 && call[2] === "target"));
  for (const operation of ["list", "resolve", "message", "control", "subscribe", "unsubscribe"]) assert.ok(calls.some((call) => call[0] === operation), `${operation} handler was not invoked`);
});

test("protobuf request builders preserve typed modes, fences inputs, ACK outcomes and no client authority", () => {
  const tell = buildActorMessage(1, "target", "hello", "dedupe", "chain", 41n); assert.equal(tell.mode, 1); assert.equal(tell.target, "target"); assert.equal(tell.hopLimit, 8); assert.equal(tell.sourceMutationSequence, 41n); assert.equal("sourceAgentId" in tell, false); assert.equal("requiredCapability" in tell, false);
  const control = buildActorControl(1, "target", "control-dedupe", "control-chain", 42n); assert.equal(control.intent, 1); assert.equal(control.hopLimit, 2); assert.equal(control.sourceMutationSequence, 42n);
  assert.deepEqual(buildDeliveryAck("agent", { sequence: 9n, dedupeId: "d" }, true, ""), { agentId: "agent", sequence: 9n, dedupeId: "d", delivered: true, reason: "", boundedResult: new Uint8Array() });
  assert.equal(buildDeliveryAck("agent", { sequence: 9n, dedupeId: "d" }, false, "failed").delivered, false);
});

test("exact mutation sequencing reconciles pre-write and response-loss without duplicate execution", async () => {
  const sequencer = new ExactMutationSequencer();
  let reconciles = 0, messageExecutions = 0, messageCreates = 0;
  const messageAttempts = [];
  const first = await sequencer.run("message-scope", (sequence) => { messageCreates++; return { sequence, requestId: "request", dedupeId: "dedupe", chainId: "chain", payload: "payload" }; }, async (logical) => {
    messageAttempts.push(structuredClone(logical));
    if (messageAttempts.length === 1) throw new Error("before-write");
    messageExecutions++; return { accepted: true, completed: true };
  }, async () => { reconciles++; });
  assert.equal(first.accepted, true); assert.equal(messageCreates, 1); assert.equal(messageExecutions, 1); assert.deepEqual(messageAttempts[0], messageAttempts[1]);
  const nextMessage = await sequencer.run("message-scope", (sequence) => ({ sequence }), async (logical) => ({ accepted: true, sequence: logical.sequence }), async () => {});
  assert.equal(nextMessage.sequence, 2n);

  let controlExecutions = 0, controlAttempts = 0; const controlLogical = [];
  await sequencer.run("control-scope", (sequence) => ({ sequence, requestId: "control-request", dedupeId: "control-dedupe", chainId: "control-chain", intent: 1 }), async (logical) => {
    controlAttempts++; controlLogical.push(structuredClone(logical));
    if (controlAttempts === 1) { controlExecutions++; throw new Error("response-loss"); }
    return { accepted: true };
  }, async () => { reconciles++; });
  assert.equal(controlExecutions, 1); assert.deepEqual(controlLogical[0], controlLogical[1]);
  const nextControl = await sequencer.run("control-scope", (sequence) => ({ sequence }), async (logical) => ({ accepted: true, sequence: logical.sequence }), async () => {});
  assert.equal(nextControl.sequence, 2n); assert.equal(reconciles, 2);
  const serialized = new ExactMutationSequencer(); let active=0,maxActive=0;const seen=[];
  await Promise.all([0,1].map(()=>serialized.run("same",(sequence)=>({sequence}),async(logical)=>{active++;maxActive=Math.max(maxActive,active);seen.push(logical.sequence);await new Promise((resolve)=>setTimeout(resolve,5));active--;return {accepted:true};},async()=>{})));
  assert.equal(maxActive,1);assert.deepEqual(seen,[1n,2n]);
});

test("unresolved message and control mutations survive retry exhaustion and reconcile before sequence two", async () => {
  for (const kind of ["message","control"]) {
    const sequencer=new ExactMutationSequencer();let attempts=0,serverExecutions=0,creates=0;const identities=[];
    const attempt=async(logical)=>{attempts++;identities.push(structuredClone(logical));if(attempts===3)serverExecutions++;if(attempts<=7)throw new Error(["pre-write","write","response-loss","timeout","malformed","correlation","disconnect"][attempts-1]);return {accepted:true,kind};};
    const create=(sequence)=>{creates++;return {sequence,requestId:`${kind}-request`,dedupeId:`${kind}-dedupe`,chainId:`${kind}-chain`,target:"target",payload:kind,intent:kind==="control"?1:undefined};};
    await assert.rejects(()=>sequencer.run(`${kind}-scope`,create,attempt,async()=>{}));
    assert.equal(sequencer.unresolvedCount(),1);assert.equal(creates,1);
    const sequenceTwo=await sequencer.run(`${kind}-scope`,(sequence)=>({sequence,requestId:`${kind}-two`} ),async(logical)=>{serverExecutions++;return {accepted:true,sequence:logical.sequence};},async()=>{});
    assert.equal(sequenceTwo.sequence,2n);assert.equal(serverExecutions,2);assert.equal(creates,1);for(const identity of identities)assert.deepEqual(identity,identities[0]);assert.equal(sequencer.unresolvedCount(),0);
  }
  const fenced=new ExactMutationSequencer();let failures=0;await assert.rejects(()=>fenced.run("old",(sequence)=>({sequence}),async()=>{failures++;throw new Error("offline")},async()=>{}));assert.equal(fenced.unresolvedCount(),1);assert.throws(()=>fenced.retireScope("old",false));assert.equal(fenced.unresolvedCount(),1);fenced.retireScope("old",true);assert.equal(fenced.unresolvedCount(),0);assert.equal(failures,5);
});

test("communication UI formatting resists spoofing, dedupes, bounds previews, and hides raw sensitive IDs", () => {
  const source = { stableId: "client:raw-principal", displayName: "PROJECT MANAGER", role: "PROJECT MANAGER" };
  const target = { stableId: "agent-raw-id", displayName: "Worker Alpha", role: "WORKER" };
  const line = communicationLine(source, target, "Tell", new TextEncoder().encode("hello session-abc credential-abc handle-abc fence-1 pid-2\n" + "x".repeat(200)));
  assert.match(line, /PROJECT MANAGER/);
  assert.match(line, /Worker Alpha/);
  assert.match(line, /Tell/);
  assert.ok(line.length <= 160);
  for (const forbidden of ["client:raw-principal", "session", "credential", "handle", "fence", "pid"]) assert.doesNotMatch(line, new RegExp(forbidden, "i"));
  const timeline = new CommunicationTimeline(3);
  const sameLine = "PROJECT MANAGER → Worker Alpha · Tell — same";
  assert.equal(timeline.add({ key: communicationKey({ dedupeId: "d1", sequence: 1n, kind: 1 }), line: sameLine }), true);
  assert.equal(timeline.add({ key: communicationKey({ dedupeId: "d1", sequence: 1n, kind: 1 }), line: "replay suppressed" }), false);
  assert.equal(timeline.add({ key: communicationKey({ dedupeId: "d2", sequence: 2n, kind: 1 }), line: sameLine }), true);
  assert.equal(timeline.add({ key: communicationKey({ dedupeId: "d3", sequence: 3n, kind: 1 }), line: "three" }), true);
  assert.equal(timeline.add({ key: communicationKey({ dedupeId: "d4", sequence: 4n, kind: 1 }), line: "four" }), true);
  assert.deepEqual(timeline.lines(), [sameLine, "three", "four"]);
});

test("communication view model renders direction, request replies, redaction, and model prompt injection", () => {
  const peer = { stableId: "principal-raw", displayName: "Beta Reviewer", role: "CODE REVIEWER" };
  const note = incomingNote("k1", peer, "hello session-secret credential-abc pid-42");
  assert.equal(note.direction, "incoming");
  assert.equal(note.intent, "note");
  assert.match(note.body, /\[redacted\]/);
  assert.doesNotMatch(JSON.stringify(note), /principal-raw|session-secret|credential-abc|pid-42/i);

  const ask = outgoingExchange({ key: "k2", target: peer, mode: "ask", accepted: true, completed: true, body: "question", reply: "answer" });
  assert.equal(ask.direction, "outgoing");
  assert.equal(ask.intent, "request");
  assert.equal(ask.state, "replied");
  assert.equal(ask.body, "question");
  assert.equal(ask.reply, "answer");

  const prompt = incomingRequestText({ source: peer, boundedPayload: new TextEncoder().encode("please work") });
  assert.match(prompt, /Beta Reviewer · code reviewer asked you/);
  assert.match(prompt, /please work/);

  const colors = [];
  const theme = { fg: (name, text) => (colors.push(name), text), bg: (_name, text) => text, bold: (text) => `**${text}**` };
  const lines = renderCommunicationCard({ ...ask, durationMillis: 8000 }, theme).render(80).join("\n");
  assert.ok(colors.includes("magenta") || colors.includes("accent"));
  assert.match(lines, /↗ Asked Beta Reviewer · code reviewer/);
  assert.match(lines, /question/);
  assert.match(lines, /↙ Beta Reviewer replied/);
  assert.match(lines, /answer/);
  assert.match(lines, /✓ replied in 8s/);
  colors.length = 0;
  const tellLines = renderCommunicationCard(outgoingExchange({ key: "tell", target: peer, mode: "tell", accepted: true, completed: true, body: "ready" }), theme).render(80).join("\n");
  assert.ok(colors.includes("blue") || colors.includes("toolTitle"));
  assert.match(tellLines, /↑ Sent to Beta Reviewer · code reviewer/);
  assert.match(tellLines, /✓ delivered/);
});

test("actor tool rendering is compact and does not expose raw protocol fields", () => {
  assert.equal(compactToolCall("actor_ask", { target: "beta", message: "Reply exactly BODY_ASK_CONTENT_OK" }), "Ask beta: Reply exactly BODY_ASK_CONTENT_OK");
  assert.equal(compactToolResult("actor_ask", { answer: "BODY_ASK_CONTENT_OK", sessionId: "raw-session", handle: "raw-handle" }), "Reply: BODY_ASK_CONTENT_OK");
  assert.doesNotMatch(compactToolResult("actor_status", { displayName: "Beta", role: "CODE REVIEWER", state: 3, runtimeId: "raw-runtime", fence: 1n }), /runtime|fence|raw/i);
});

test("typed delivery invokes documented context abort/shutdown and notification methods", async () => {
  const calls = []; const ctx = { abort() { calls.push("abort"); }, shutdown() { calls.push("shutdown"); }, ui: { notify(text) { calls.push(["notify", text]); } } };
  executeTypedDelivery(ctx, 1, "notice"); executeTypedDelivery(ctx, 2, ""); executeTypedDelivery(ctx, 3, "");
  assert.deepEqual(calls, [["notify", "notice"], "abort", "shutdown"]);
  const success = await invokeTypedDeliveryForAck("agent", { sequence: 1n, dedupeId: "ok" }, () => ctx.abort());
  const failure = await invokeTypedDeliveryForAck("agent", { sequence: 2n, dedupeId: "failed" }, () => { throw new Error("abort failed"); });
  assert.equal(success.delivered, true); assert.equal(failure.delivered, false); assert.equal(failure.reason, "abort failed");
});

test("ordinary bytes cannot select abort or shutdown semantics", () => {
  assert.equal(deliveryAction(1), "notify");
  assert.equal(deliveryAction(2), "abort");
  assert.equal(deliveryAction(3), "shutdown");
  assert.throws(() => deliveryAction(0), /unsupported/);
});

test("prompt delivery uses sendUserMessage then agent_end returns one bounded answer", async () => {
  const sent=[];const acknowledgements=[];
  const coordinator=new PromptTaskCoordinator((text)=>sent.push(text),async(pending,delivered,answer,reason)=>acknowledgements.push({pending,delivered,answer,reason}));
  const delivery={dedupeId:"d1",boundedPayload:new TextEncoder().encode("implement next task"),hopLimit:7,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain",sequence:1n};
  await coordinator.deliver(delivery,{handle:"h",fence:1n});
  assert.deepEqual(sent,["implement next task"]);
  await coordinator.agentEnd([{role:"assistant",content:[{type:"text",text:"completed answer"}]}]);
  assert.equal(acknowledgements.length,1);assert.equal(acknowledgements[0].delivered,true);assert.equal(acknowledgements[0].answer,"completed answer");assert.equal(coordinator.active(),undefined);
  await coordinator.agentEnd([{role:"assistant",content:"duplicate"}]);
  assert.equal(acknowledgements.length,1,"duplicate agent_end acknowledged twice");
});

test("prompt completion survives acknowledgement response loss and reconnect", async () => {
  let attempts=0;const sent=[];
  const coordinator=new PromptTaskCoordinator((text)=>sent.push(text),async(_pending,_delivered,answer)=>{attempts++;assert.equal(answer,"durable answer");if(attempts===1)throw new Error("response lost");});
  const delivery={dedupeId:"d2",boundedPayload:new TextEncoder().encode("task"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain-2",sequence:2n};
  await coordinator.deliver(delivery,{handle:"h",fence:2n});
  await assert.rejects(()=>coordinator.agentEnd([{role:"assistant",content:"durable answer"}]),/response lost/);
  assert.ok(coordinator.active(),"response loss discarded prompt completion");
  await coordinator.retryCompletion();
  assert.equal(attempts,2);assert.equal(coordinator.active(),undefined);assert.deepEqual(sent,["task"]);
});
