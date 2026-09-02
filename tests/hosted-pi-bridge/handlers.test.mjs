import assert from "node:assert/strict";
import test from "node:test";
import { buildActorControl, buildActorMessage, buildIdentityDeliveryAck, bridgeErrorClass, communicationKey, communicationLine, CommunicationTimeline, completeHostedEnvironment, ExactMutationSequencer, PromptTaskCoordinator, deliveryAction, deliveryKindLabel, destroyOnFramingFailure, drainPages, executeTypedDelivery, invokeTypedDeliveryForAck, missingAckIdentity, parseTargetMessage, registerHostedHandlers, requireExplicitModelTarget } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/handlers.ts";
import { bridgeDiagnostic, incomingNote, incomingRequestText, outgoingExchange, renderCommunicationCard, compactToolCall, compactToolResult, modelResultContent } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/communication-ui.ts";
import { actorControlCapabilities, actorMessageCapabilities, actorMessageModelResult, capabilitySetIncludes, connectBridgeWithRetry, consumeReconnect, degradedBridgeStatus, resolveHostedMessageDestination } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/index.ts";

const complete = { WS_SUBAGENTS_ENDPOINT: "ws://127.0.0.1:17213/actors", WS_SUBAGENTS_CREDENTIAL_FILE: "/state/credential", WS_SUBAGENTS_SESSION_ID: "session", WS_SUBAGENTS_GENERATION_ID: "generation", WS_SUBAGENTS_CALLER: "hosted:agent", WS_SUBAGENTS_AGENT_ID: "agent", WS_SUBAGENTS_RUNTIME_ID: "runtime", WS_SUBAGENTS_INCARNATION: "1" };

test("fire-and-forget reconnect exhaustion never becomes an unhandled rejection", async () => {
  consumeReconnect(async () => { throw new Error("planned reconnect exhaustion"); });
  await new Promise((resolve) => setImmediate(resolve));
});

test("bridge startup passes the dynamically imported connect schema explicitly", async () => {
  const schema = { typeName: "test.BridgeConnectRequest" };
  let observed;
  const client = { request: async (_case, passed) => { observed = passed; return { payload: { case: "bridgeConnectResponse", value: { accepted: true, agentHandle: "handle", fence: 1n } } }; } };
  const binding = { agentId: "agent", runtimeId: "runtime", incarnation: 1n };
  const response = await connectBridgeWithRetry(client, binding, "pi-session", 0n, schema, 1, async () => {});
  assert.equal(observed, schema);
  assert.equal(response.payload.value.accepted, true);
});

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

test("hosted reply target aliases resolve only to authoritative source", () => {
  const delivery = { source: { stableId: "client:terminal-1", displayName: "PROJECT MANAGER" } };
  assert.equal(resolveHostedMessageDestination("Project Manager", "worker", delivery), "client:terminal-1");
  assert.equal(resolveHostedMessageDestination("reply-to-source", "worker", delivery), "client:terminal-1");
  assert.equal(resolveHostedMessageDestination("worker-two", "worker", delivery), "worker-two");
  assert.throws(() => resolveHostedMessageDestination("project-manager", "worker"), /not an authoritative reply target/);
  assert.throws(() => resolveHostedMessageDestination("pm", "worker", { source: { stableId: "project-manager" } }), /not an authoritative reply target/);
});

test("target attachment fences are operation-minimal and capability-set scoped", () => {
  assert.deepEqual(actorMessageCapabilities(1), ["observe", "send"]);
  assert.deepEqual(actorMessageCapabilities(2), ["observe", "ask"]);
  assert.deepEqual(actorControlCapabilities(1), ["observe", "control_abort"]);
  assert.deepEqual(actorControlCapabilities(2), ["observe", "control_shutdown"]);
  assert.equal(capabilitySetIncludes(["send", "observe"], actorMessageCapabilities(1)), true, "an existing messaging fence may be reused regardless of capability order");
  assert.equal(capabilitySetIncludes(actorMessageCapabilities(1), actorControlCapabilities(1)), false, "messaging-only fences must be replaced for a control operation");
  assert.doesNotMatch(actorMessageCapabilities(1).join(" "), /control_abort|control_shutdown/, "actor_tell must never request control capabilities");
  assert.throws(() => actorControlCapabilities(99), /unsupported actor control intent/);
});

test("actual registered command and tool callbacks invoke every hosted operation", async () => {
  const commands = new Map(), tools = new Map(), calls = [];
  const api = { registerCommand(name, registration) { commands.set(name, registration); }, registerTool(registration) { tools.set(registration.name, registration); } };
  const operations = {
    async list() { calls.push(["list"]); return { ok: true }; }, async resolve(target) { calls.push(["resolve", target]); return {}; }, async health(target) { calls.push(["health", target]); return { reachable: true }; },
    async message(mode, target, text) { calls.push(["message", mode, target, text]); return { accepted: true, completed: false }; },
    async control(intent, target) { calls.push(["control", intent, target]); return { accepted: true }; },
    async subscribe(target) { calls.push(["subscribe", target]); return { completed: true }; }, async unsubscribe(target) { calls.push(["unsubscribe", target]); return { completed: true }; },
  };
  registerHostedHandlers(api, operations, { empty: {}, target: {}, modelTarget: {}, message: {} });
  const notices = [];
  const context = { ui: { notify(message) { notices.push(message); } } };
  await commands.get("actor-list").handler("", context); await commands.get("actor-resolve").handler("", context);
  const beforeMessageNotices = notices.length;
  await commands.get("actor-tell").handler("target -- question", context);
  assert.ok(notices.length>=beforeMessageNotices, "command-driven async messages return receipts");
  await commands.get("actor-abort").handler("target", context); await commands.get("actor-shutdown").handler("target", context);
  await commands.get("actor-subscribe").handler("target", context); await commands.get("actor-unsubscribe").handler("target", context);
  for (const [name, params] of [["actor_list", {}], ["actor_resolve", { target: "target" }], ["actor_health", { target: "target" }], ["actor_tell", { target: "target", message: "tell async" }], ["actor_abort", { target: "target" }], ["actor_shutdown", { target: "target" }], ["actor_subscribe", { target: "target" }], ["actor_unsubscribe", { target: "target" }]]) {
    const registration = tools.get(name);
    const result = await registration.execute("id", params);
    assert.equal(typeof registration.renderCall, "function");
    assert.equal(typeof registration.renderResult, "function");
    assert.doesNotMatch(result.content[0].text, /^\s*[\[{]/, `${name} exposed raw JSON as tool content`);
  }
  await assert.rejects(() => tools.get("actor_tell").execute("id", { message: "implicit" }), /explicit target/);
  assert.equal(commands.size, 8); assert.equal(tools.size, 8);
  assert.ok(calls.some((call) => call[0] === "message" && call[1] === 2 && call[2] === "target"));
  for (const operation of ["list", "resolve", "health", "message", "control", "subscribe", "unsubscribe"]) assert.ok(calls.some((call) => call[0] === operation), `${operation} handler was not invoked`);
});

test("protobuf request builders preserve typed modes, fences inputs, ACK outcomes and no client authority", () => {
  const tell = buildActorMessage(1, "target", "hello", "dedupe", "chain", 41n); assert.equal(tell.mode, 1); assert.equal(tell.target, "target"); assert.equal(tell.hopLimit, 8); assert.equal(tell.sourceMutationSequence, 41n); assert.equal("sourceAgentId" in tell, false); assert.equal("requiredCapability" in tell, false);
  const control = buildActorControl(1, "target", "control-dedupe", "control-chain", 42n); assert.equal(control.intent, 1); assert.equal(control.hopLimit, 2); assert.equal(control.sourceMutationSequence, 42n);
  const identity = { runtimeId: "runtime-9", incarnation: 2n, piSessionId: "pi-9" };
  const ackable = { sequence: 9n, dedupeId: "d", kind: 1, sourceScope: "scope-key", completionKey: "completion-key" };
  assert.deepEqual(buildIdentityDeliveryAck("agent", identity, ackable, true, ""), { agentId: "agent", sequence: 9n, dedupeId: "d", delivered: true, reason: "", boundedResult: new Uint8Array(), runtimeId: "runtime-9", incarnation: 2n, piSessionId: "pi-9", kind: "notification", sourceScope: "scope-key", completionKey: "completion-key" });
  assert.equal(buildIdentityDeliveryAck("agent", identity, ackable, false, "failed").delivered, false);
  assert.equal(deliveryKindLabel(1), "notification"); assert.equal(deliveryKindLabel(4), "prompt");
  assert.throws(() => buildIdentityDeliveryAck("agent", identity, { sequence: 9n, dedupeId: "d", kind: 1 }, true, ""), /identity is missing/);
  assert.throws(() => deliveryKindLabel(9), /unsupported/);
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

test("actor_tell model results expose exact stable correlation only", () => {
  const logical = { requestId: "request-1", value: { dedupeId: "dedupe-1", chainId: "chain-1", sourceMutationSequence: 7n } };
  const details = actorMessageModelResult(logical, { accepted: true, completed: true, boundedResult: new TextEncoder().encode("answer"), reason: "", source: { stableId: "source-actor", displayName: "session-secret", role: "MANAGER" }, target: { stableId: "target-actor", displayName: "handle-secret", role: "WORKER" }, kind: "ask" });
  assert.equal(details.requestId, "request-1");
  assert.equal(details.dedupeId, "dedupe-1");
  assert.equal(details.chainId, "chain-1");
  assert.equal(details.sourceMutationSequence, "7");
  assert.equal(details.source, "source-actor");
  assert.equal(details.target, "target-actor");
  assert.equal(details.kind, "ask");
  const visible = modelResultContent("actor_tell", details);
  for (const required of ["requestId=request-1", "dedupeId=dedupe-1", "chainId=chain-1", "sourceMutationSequence=7", "source=source-actor", "target=target-actor", "kind=ask"]) assert.match(visible, new RegExp(required));
  assert.doesNotMatch(visible, /session-secret|handle-secret/);
  assert.throws(() => actorMessageModelResult({ requestId: "bad\nrequest", value: { dedupeId: "dedupe", chainId: "chain", sourceMutationSequence: 1n } }, { boundedResult: new Uint8Array(), kind: "tell" }), /requestId/);
});

test("bridge diagnostics render bounded payload-free lifecycle cards", () => {
  const ok = bridgeDiagnostic({ key: "diag\0test-ok", line: "prompt ack · agent=agent-7 · sequence=12 · outcome=accepted · delivered=true" });
  assert.equal(ok.direction, "outgoing");
  assert.equal(ok.intent, "control");
  assert.equal(ok.state, "delivered");
  assert.match(ok.body, /sequence=12 · outcome=accepted/);
  const failed = bridgeDiagnostic({ key: "diag\0test-failed", line: `prompt ack · agent=${"x".repeat(400)} · sequence=13 · outcome=error · class=transport`, failed: true });
  assert.equal(failed.intent, "failure");
  assert.equal(failed.state, "failed");
  assert.ok(failed.body.length <= 200, `diagnostic body must stay bounded: ${failed.body.length}`);
  assert.doesNotMatch(failed.body, /[\r\n\t\x00]/);
});

test("actor tool rendering is compact and does not expose raw protocol fields", () => {
  assert.equal(compactToolCall("actor_tell", { target: "beta", message: "Reply exactly BODY_ASK_CONTENT_OK" }), "Tell beta: Reply exactly BODY_ASK_CONTENT_OK");
  assert.equal(compactToolResult("actor_tell", { accepted: true, completed: false, sessionId: "raw-session", handle: "raw-handle" }), "Request accepted");
  assert.doesNotMatch(compactToolResult("actor_health", { displayName: "Beta", role: "CODE REVIEWER", state: 3, runtimeId: "raw-runtime", fence: 1n }), /runtime|fence|raw/i);
});

test("typed delivery invokes documented context abort/shutdown and notification methods", async () => {
  const calls = []; const ctx = { abort() { calls.push("abort"); }, shutdown() { calls.push("shutdown"); }, ui: { notify(text) { calls.push(["notify", text]); } } };
  executeTypedDelivery(ctx, 1, "notice"); executeTypedDelivery(ctx, 2, ""); executeTypedDelivery(ctx, 3, "");
  assert.deepEqual(calls, [["notify", "notice"], "abort", "shutdown"]);
  const identity = { runtimeId: "runtime-9", incarnation: 2n, piSessionId: "pi-9" };
  const okDelivery = { sequence: 1n, dedupeId: "ok", kind: 2, sourceScope: "scope-key", completionKey: "completion-key" };
  const failedDelivery = { sequence: 2n, dedupeId: "failed", kind: 2, sourceScope: "scope-key", completionKey: "completion-key" };
  const success = await invokeTypedDeliveryForAck("agent", identity, okDelivery, () => ctx.abort());
  const failure = await invokeTypedDeliveryForAck("agent", identity, failedDelivery, () => { throw new Error("abort failed"); });
  assert.equal(success.ack.delivered, true); assert.equal(failure.ack.delivered, false); assert.equal(failure.ack.reason, "abort failed");
  assert.equal(success.ack.kind, "abort"); assert.equal(success.ack.completionKey, "completion-key");
  // A delivery failure must surface through the built acknowledgement, never
  // by re-throwing out of the wrapper: the acknowledgement still commits with
  // delivered=false so the daemon cursor advances instead of stalling.
  assert.equal(failure.degraded, undefined);
});

test("missing acknowledgement identity degrades visibly without side effects or re-throw", async () => {
  const identity = { runtimeId: "runtime-9", incarnation: 2n, piSessionId: "pi-9" };
  const executed = [];
  for (const stripped of [
    { sequence: 12n, dedupeId: "legacy-both", kind: 4 },
    { sequence: 13n, dedupeId: "legacy-scope", kind: 1, completionKey: "completion-key" },
    { sequence: 14n, dedupeId: "legacy-key", kind: 2, sourceScope: "scope-key" },
  ]) {
    const outcome = await invokeTypedDeliveryForAck("agent", identity, stripped, () => { executed.push(stripped.dedupeId); });
    assert.equal(outcome.ack, undefined, `${stripped.dedupeId} unexpectedly built an acknowledgement`);
    assert.match(outcome.degraded, /delivery acknowledgement identity is missing/);
    assert.match(outcome.degraded, new RegExp(String.raw`sequence ${stripped.sequence}`));
    assert.match(degradedBridgeStatus(new Error(outcome.degraded)), /^hosted bridge degraded · delivery acknowledgement identity is missing/);
  }
  assert.deepEqual(executed, [], "identity-less delivery side effects must not run");
  assert.equal(missingAckIdentity({ sequence: 1n, dedupeId: "d", kind: 1, sourceScope: "s", completionKey: "c" }), undefined);
  assert.match(missingAckIdentity({ sequence: 1n, dedupeId: "d", kind: 1 }), /identity is missing/);
});

test("ordinary bytes cannot select abort or shutdown semantics", () => {
  assert.equal(deliveryAction(1), "notify");
  assert.equal(deliveryAction(2), "abort");
  assert.equal(deliveryAction(3), "shutdown");
  assert.throws(() => deliveryAction(0), /unsupported/);
});

test("acknowledgement rejection surfaces as a bounded visible degradation reason", () => {
  const rejected = degradedBridgeStatus(new Error("delivery acknowledgement rejected: delivery acknowledgement identity rejected"));
  assert.match(rejected, /^hosted bridge degraded · delivery acknowledgement rejected: delivery acknowledgement identity rejected$/);
  const missing = degradedBridgeStatus(new Error("delivery acknowledgement identity is missing"));
  assert.match(missing, /identity is missing$/);
  const bounded = degradedBridgeStatus(new Error("x".repeat(500) + "\n\tinjection"));
  assert.ok(bounded.length <= 130, `degradation status must stay bounded: ${bounded.length}`);
  assert.doesNotMatch(bounded, /[\r\n\t]/);
  assert.match(degradedBridgeStatus("plain failure"), /hosted bridge degraded · plain failure$/);
});

test("prompt delivery injects followUp, correlates the settled answer, and ignores duplicate runs", async () => {
  const sent=[];const acknowledgements=[];const events=[];
  const coordinator=new PromptTaskCoordinator((text)=>sent.push(text),async(pending,delivered,answer,reason)=>acknowledgements.push({pending,delivered,answer,reason}),(event)=>events.push(event));
  const delivery={dedupeId:"d1",boundedPayload:new TextEncoder().encode("implement next task"),hopLimit:7,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain",sequence:1n};
  await coordinator.deliver(delivery,{handle:"h",fence:1n});
  assert.deepEqual(sent,["implement next task"]);
  // An agent_end from a run that never included the prompt carries no
  // correlated answer and must not acknowledge.
  await coordinator.agentEnd([{role:"user",content:"unrelated"}]);
  await coordinator.settled();
  assert.equal(acknowledgements.length,1,"run without an assistant answer acknowledged exactly once as failed");
  assert.equal(acknowledgements[0].delivered,false);
  assert.match(acknowledgements[0].reason,/without an assistant answer/);
  assert.equal(coordinator.active(),undefined);
  await coordinator.agentEnd([{role:"assistant",content:"duplicate"}]);
  await coordinator.settled();
  assert.equal(acknowledgements.length,1,"duplicate agent_end acknowledged twice");
  assert.deepEqual(events.map((event)=>event.stage),["injected","failed"]);
  for (const event of events) { assert.equal(typeof event.sequence,"bigint"); assert.ok(!/[\r\n\t]/.test(event.detail)); }
});

test("prompt completion correlates the answer only when the session settles", async () => {
  const acknowledgements=[];
  const coordinator=new PromptTaskCoordinator(async()=>{},async(_pending,delivered,answer,reason)=>acknowledgements.push({delivered,answer,reason}));
  const delivery={dedupeId:"d-answer",boundedPayload:new TextEncoder().encode("task"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain",sequence:5n};
  await coordinator.deliver(delivery,{handle:"h",fence:5n});
  await coordinator.agentEnd([{role:"assistant",content:[{type:"text",text:"partial"}]}]);
  assert.equal(acknowledgements.length,0,"agent_end alone must never acknowledge");
  await coordinator.settled();
  assert.equal(acknowledgements.length,1);assert.equal(acknowledgements[0].delivered,true);assert.equal(acknowledgements[0].answer,"partial");
  assert.equal(coordinator.active(),undefined);
});

test("unobservable prompt injection failures still terminally acknowledge", async () => {
  const acknowledgements=[];const events=[];
  const coordinator=new PromptTaskCoordinator(()=>{throw new Error("Extension runtime is stale");},async(_pending,delivered,answer,reason)=>acknowledgements.push({delivered,answer,reason}),(event)=>events.push(event));
  const delivery={dedupeId:"d-inject",boundedPayload:new TextEncoder().encode("task"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain",sequence:6n};
  await coordinator.deliver(delivery,{handle:"h",fence:6n});
  assert.equal(acknowledgements.length,1);
  assert.equal(acknowledgements[0].delivered,false);
  assert.match(acknowledgements[0].reason,/stale/);
  await coordinator.settled();
  assert.equal(acknowledgements.length,1);
  assert.equal(coordinator.active(),undefined);
  assert.deepEqual(events.map((event)=>event.stage),["failed"]);
});

test("stalled prompts expire at their delivery deadline and abandoned tasks free the coordinator", async () => {
  const acknowledgements=[];
  const coordinator=new PromptTaskCoordinator(async()=>{},async(_pending,delivered,_answer,reason)=>acknowledgements.push({delivered,reason}));
  const expired={dedupeId:"d-expired",boundedPayload:new TextEncoder().encode("task"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()-1),chainId:"chain",sequence:7n};
  await assert.rejects(()=>coordinator.deliver(expired,{handle:"h",fence:7n}),/deadline expired/);
  const stalled={dedupeId:"d-stalled",boundedPayload:new TextEncoder().encode("task"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()+50),chainId:"chain",sequence:8n};
  await coordinator.deliver(stalled,{handle:"h",fence:8n});
  assert.equal(await coordinator.expireStalled(Date.now()),false);
  await new Promise((resolve)=>setTimeout(resolve,60));
  assert.equal(await coordinator.expireStalled(Date.now()),true);
  assert.equal(acknowledgements.length,1);assert.equal(acknowledgements[0].delivered,false);assert.match(acknowledgements[0].reason,/deadline expired before completion/);
  assert.equal(coordinator.active(),undefined);
  await coordinator.deliver({dedupeId:"d-next",boundedPayload:new TextEncoder().encode("next"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain",sequence:9n},{handle:"h",fence:9n});
  assert.equal(coordinator.abandon("delivery is not retained"),true);
  assert.equal(coordinator.active(),undefined);
  assert.equal(coordinator.abandon("again"),false);
  await coordinator.settled();
  assert.equal(acknowledgements.length,1,"abandoned task never acknowledges");
});

test("bridge error classes are coarse, bounded, and payload-free", () => {
  assert.equal(bridgeErrorClass(new Error("hosted bridge is disconnected")),"transport");
  assert.equal(bridgeErrorClass(new Error("daemon websocket error")),"transport");
  assert.equal(bridgeErrorClass(new Error("daemon response deadline expired")),"timeout");
  assert.equal(bridgeErrorClass(new Error("daemon frame bound violated")),"framing");
  assert.equal(bridgeErrorClass(new Error("hosted bridge response correlation mismatch")),"correlation");
  assert.equal(bridgeErrorClass(new Error("prompt completion acknowledgement rejected: identity")),"rejected");
  assert.equal(bridgeErrorClass(new Error("delivery acknowledgement identity is missing")),"identity");
  assert.equal(bridgeErrorClass(new Error("something else")),"unknown");
  assert.equal(bridgeErrorClass("plain"),"unknown");
});

test("prompt completion survives acknowledgement response loss and reconnect", async () => {
  let attempts=0;const sent=[];
  const coordinator=new PromptTaskCoordinator((text)=>sent.push(text),async(_pending,_delivered,answer)=>{attempts++;assert.equal(answer,"durable answer");if(attempts===1)throw new Error("response lost");});
  const delivery={dedupeId:"d2",boundedPayload:new TextEncoder().encode("task"),hopLimit:4,deadlineUnixMillis:BigInt(Date.now()+1000),chainId:"chain-2",sequence:2n};
  await coordinator.deliver(delivery,{handle:"h",fence:2n});
  await coordinator.agentEnd([{role:"assistant",content:"durable answer"}]);
  await assert.rejects(()=>coordinator.settled(),/response lost/);
  assert.ok(coordinator.active(),"response loss discarded prompt completion");
  await coordinator.retryCompletion();
  assert.equal(attempts,2);assert.equal(coordinator.active(),undefined);assert.deepEqual(sent,["task"]);
});
