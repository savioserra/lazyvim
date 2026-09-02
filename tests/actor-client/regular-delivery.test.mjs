import assert from "node:assert/strict";
import test from "node:test";
import { REGULAR_DELIVERY_MARKER, RegularDeliveryCoordinator, acknowledgeWithFenceRefresh } from "../../home/dot_pi/private_agent/extensions/actor-client/regular-delivery.ts";
import { projectIncomingRegularDelivery } from "../../home/dot_pi/private_agent/extensions/actor-client/index.ts";
import { initialProjectionContext } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/machine.ts";

function delivery(kind, overrides={}) {
  return {sequence:1n,source:{stableId:"worker",displayName:"Worker",role:"implementer"},targetAgentId:"client:pm",requestId:"request",dedupeId:"dedupe",chainId:"chain",deadlineUnixMillis:BigInt(Date.now()+60_000),hopLimit:7,boundedPayload:new TextEncoder().encode(kind===4?"Please answer this request":"Worker report arrived"),kind,sourceScope:"scope",completionKey:"completion",...overrides};
}
function harness(entries=[]) {
  const markers=[];const messages=[];const acks=[];
  const coordinator=new RegularDeliveryCoordinator({appendMarker:(marker)=>markers.push({type:"custom",customType:REGULAR_DELIVERY_MARKER,data:marker}),sendFollowUp:(message,text)=>messages.push({message,text}),acknowledge:async(item,_fence,delivered,answer,reason)=>acks.push({item,delivered,answer,reason})});
  coordinator.restore(entries);
  return {coordinator,markers,messages,acks};
}
const fence={handle:"regular",fence:1n};

test("regular delivery ack refreshes stale self fence once with identical delivery payload", async () => {
  const calls=[];
  const stale={handle:"old",fence:1n};
  const fresh={handle:"new",fence:2n};
  await acknowledgeWithFenceRefresh(stale, async (fence) => {
    calls.push(fence);
    if (calls.length === 1) throw new Error("delivery acknowledgement fence rejected");
  }, async () => fresh);
  assert.deepEqual(calls, [stale, fresh]);
  calls.length = 0;
  await assert.rejects(() => acknowledgeWithFenceRefresh(stale, async (fence) => { calls.push(fence); throw new Error("delivery acknowledgement fence rejected"); }, async () => fresh), /fence rejected/);
  assert.deepEqual(calls, [stale, fresh]);
});

test("bridge push projects incoming tell through root before one render-envelope message",async()=>{
  let projection=initialProjectionContext();
  const messages=[];const markers=[];const acks=[];
  const coordinator=new RegularDeliveryCoordinator({
    appendMarker:(marker)=>markers.push(marker),
    projectIncoming:(_delivery,prompt,card)=>{const projected=projectIncomingRegularDelivery(projection,prompt,card);projection=projected.context;return projected.message;},
    sendFollowUp:(message,text)=>messages.push({message,text}),
    acknowledge:async(item,_fence,delivered,answer,reason)=>acks.push({item,delivered,answer,reason}),
  });
  await coordinator.deliver(delivery(1),fence);
  assert.equal(messages.length,1);
  assert.equal(messages[0].message.renderEnvelope.schemaVersion,1);
  assert.equal(messages[0].message.renderEnvelope.renderSnapshot.card.intent,"note");
  assert.equal(messages[0].message.view,undefined);
  assert.equal(projection.snapshot.cards.length,1);
  assert.equal(acks.length,1);
});

test("bridge push projects incoming request once without duplicate conversation card",async()=>{
  let projection=initialProjectionContext();
  const messages=[];
  const coordinator=new RegularDeliveryCoordinator({
    appendMarker:()=>{},
    projectIncoming:(_delivery,prompt,card)=>{const projected=projectIncomingRegularDelivery(projection,prompt,card);projection=projected.context;return projected.message;},
    sendFollowUp:(message,text)=>messages.push({message,text}),
    acknowledge:async()=>{},
  });
  await coordinator.deliver(delivery(4),fence);
  await coordinator.deliver(delivery(4),fence);
  assert.equal(messages.length,1);
  assert.equal(projection.snapshot.cards.length,1);
  assert.equal(messages[0].message.renderEnvelope.renderSnapshot.card.intent,"request");
});

test("incoming tell renders an incoming card, wakes the model once, then ACKs",async()=>{
  const h=harness();
  await h.coordinator.deliver(delivery(1),fence);
  assert.equal(h.messages.length,1);
  assert.equal(h.messages[0].message.key,"completion");
  assert.equal(h.messages[0].message.renderEnvelope.renderSnapshot.card.direction,"incoming");
  assert.equal(h.messages[0].message.renderEnvelope.renderSnapshot.card.intent,"note");
  assert.equal(h.messages[0].text,"Worker report arrived");
  assert.equal(h.acks.length,1);
  assert.equal(h.acks[0].delivered,true);
  assert.equal(h.acks[0].answer,"");
  assert.deepEqual(h.markers.map((entry)=>entry.data.stage),["injected","acked"]);
});

test("incoming ask waits for settlement and ACKs the bounded assistant answer",async()=>{
  const h=harness();
  await h.coordinator.deliver(delivery(4),fence);
  assert.equal(h.messages.length,1);
  assert.equal(h.messages[0].message.renderEnvelope.renderSnapshot.card.direction,"incoming");
  assert.equal(h.messages[0].message.renderEnvelope.renderSnapshot.card.intent,"request");
  assert.equal(h.acks.length,0,"prompt was acknowledged before a model run settled");
  h.coordinator.agentEnd([{role:"user",content:"Please answer this request"},{role:"assistant",content:[{type:"text",text:"Actual model answer"}]}]);
  await h.coordinator.settled();
  assert.equal(h.acks.length,1);
  assert.equal(h.acks[0].delivered,true);
  assert.equal(h.acks[0].answer,"Actual model answer");
  assert.notEqual(h.acks[0].answer,"delivered to terminal");
});

test("an active Ask follow-up turn cannot head-of-line block a later Tell ACK",async()=>{
  const messages=[];const acks=[];
  const never=new Promise(()=>{});
  const coordinator=new RegularDeliveryCoordinator({
    appendMarker:()=>{},
    // Some Pi surfaces return a thenable spanning the triggered model turn even
    // though sendMessage's extension contract is synchronous enqueue.
    sendFollowUp:(message,text)=>{messages.push({message,text});return never;},
    acknowledge:async(item,_fence,delivered,answer,reason)=>acks.push({item,delivered,answer,reason}),
  });
  await coordinator.deliver(delivery(4),fence);
  await coordinator.deliver(delivery(1,{sequence:2n,dedupeId:"tell",completionKey:"tell-completion"}),fence);
  assert.equal(messages.length,2);
  assert.equal(acks.length,1);
  assert.equal(acks[0].item.sequence,2n);
  assert.equal(acks[0].delivered,true);
});

test("reconnect replay restores durable markers and neither injects nor ACKs twice",async()=>{
  const first=harness();
  const item=delivery(1);
  await first.coordinator.deliver(item,fence);
  const replay=harness(first.markers);
  await replay.coordinator.deliver(item,fence);
  assert.equal(replay.messages.length,0);
  assert.equal(replay.acks.length,0);
});

test("expired incoming work terminally ACKs failure without model injection",async()=>{
  const h=harness();
  await h.coordinator.deliver(delivery(4,{deadlineUnixMillis:BigInt(Date.now()-1)}),fence);
  assert.equal(h.messages.length,0);
  assert.equal(h.acks.length,1);
  assert.equal(h.acks[0].delivered,false);
  assert.match(h.acks[0].reason,/deadline expired/);
});

test("injected prompt replay does not reinject and completes from the correlated settlement",async()=>{
  const marker={type:"custom",customType:REGULAR_DELIVERY_MARKER,data:{key:"completion",stage:"injected",kind:4}};
  const h=harness([marker]);
  await h.coordinator.deliver(delivery(4),fence);
  assert.equal(h.messages.length,0);
  assert.equal(h.acks.length,0);
  h.coordinator.agentEnd([{role:"assistant",content:"Answer after reload"}]);
  await h.coordinator.settled();
  assert.equal(h.acks.length,1);
  assert.equal(h.acks[0].answer,"Answer after reload");
});
