import assert from "node:assert/strict";
import test from "node:test";
import { REGULAR_DELIVERY_MARKER, RegularDeliveryCoordinator } from "../../home/dot_pi/private_agent/extensions/actor-client/regular-delivery.ts";

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

test("incoming tell renders an incoming card, wakes the model once, then ACKs",async()=>{
  const h=harness();
  await h.coordinator.deliver(delivery(1),fence);
  assert.equal(h.messages.length,1);
  assert.equal(h.messages[0].message.key,"completion");
  assert.equal(h.messages[0].message.view.direction,"incoming");
  assert.equal(h.messages[0].message.view.intent,"note");
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
  assert.equal(h.messages[0].message.view.direction,"incoming");
  assert.equal(h.messages[0].message.view.intent,"request");
  assert.equal(h.acks.length,0,"prompt was acknowledged before a model run settled");
  h.coordinator.agentEnd([{role:"user",content:"Please answer this request"},{role:"assistant",content:[{type:"text",text:"Actual model answer"}]}]);
  await h.coordinator.settled();
  assert.equal(h.acks.length,1);
  assert.equal(h.acks[0].delivered,true);
  assert.equal(h.acks[0].answer,"Actual model answer");
  assert.notEqual(h.acks[0].answer,"delivered to terminal");
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
