import assert from "node:assert/strict";
import test from "node:test";
import ntfyNotifier from "../extensions/ntfy-notifier.ts";
import {
  buildNotification,
  buildTopicUrl,
  classifyResult,
  extractAssistantText,
  loadConfig,
  publishNtfy,
} from "../src/ntfy.js";

test("stays disabled without explicit server and topic configuration", () => {
  const unconfigured = loadConfig({});
  assert.equal(unconfigured.enabled, false);
  assert.equal(unconfigured.server, "");
  assert.equal(unconfigured.topic, "");
  assert.equal(unconfigured.includeContext, false);

  const halfConfigured = loadConfig({ PI_NTFY_SERVER: "https://ntfy.example.test" });
  assert.equal(halfConfigured.enabled, false);

  const configured = loadConfig({
    PI_NTFY_SERVER: "https://ntfy.example.test",
    PI_NTFY_TOPIC: "pi",
  });
  assert.equal(configured.enabled, true);
});

test("classifies completed and action-needed responses", () => {
  assert.equal(classifyResult("Implemented and validated."), "complete");
  assert.equal(classifyResult("No action is needed."), "complete");
  assert.equal(classifyResult("Implemented. No further action is needed."), "complete");
  assert.equal(classifyResult("The deployment was blocked earlier, but it is now fixed."), "complete");
  assert.equal(classifyResult("I was blocked by a transient lock, but the retry succeeded."), "complete");
  assert.equal(classifyResult("We were waiting for CI, but it passed."), "complete");
  assert.equal(classifyResult("Please choose the production domain."), "action");
  assert.equal(classifyResult("Please run npm install."), "action");
  assert.equal(classifyResult("Please review the changes before deployment."), "action");
  assert.equal(classifyResult("You need to configure DNS before deployment."), "action");
  assert.equal(classifyResult("I need you to restart the service."), "action");
  assert.equal(classifyResult("No further action is needed from me. Please provide the production domain."), "action");
  assert.equal(classifyResult("Which environment should I deploy to?"), "action");
  assert.equal(classifyResult("", "toolUse"), "complete");
  assert.equal(classifyResult("", "toolUse", true), "action");
  assert.equal(classifyResult("Finished.", "error"), "action");
});

test("extracts only assistant text blocks", () => {
  const text = extractAssistantText({
    role: "assistant",
    content: [
      { type: "thinking", thinking: "secret" },
      { type: "text", text: "Public result" },
      { type: "toolCall", id: "1", name: "read", arguments: {} },
    ],
  });
  assert.equal(text, "Public result");
});

test("notification never copies assistant text into the payload", () => {
  const secret = "secret prompt result";
  const notification = buildNotification({ assistantText: secret, durationMs: 62000 });
  assert.equal(notification.kind, "complete");
  assert.equal(notification.title, "Pi completed");
  assert.match(notification.body, /1m 2s/);
  assert.doesNotMatch(notification.body, new RegExp(secret));
});

test("identifies the agent or project in the notification title", () => {
  assert.equal(
    buildNotification({ forceKind: "complete", sessionName: "security-reviewer", cwd: "/root/project" }).title,
    "Pi completed — security-reviewer",
  );
  assert.equal(
    buildNotification({ forceKind: "action", cwd: "/root/project" }).title,
    "Pi needs attention — project",
  );
});

test("builds a topic URL under a custom server path", () => {
  assert.equal(
    buildTopicUrl("https://notify.example.test/base", "pi_topic"),
    "https://notify.example.test/base/pi_topic",
  );
  assert.throws(() => buildTopicUrl("file:///tmp", "pi_topic"), /http/);
  assert.throws(() => buildTopicUrl("https://ntfy.example.test", "bad/topic"), /PI_NTFY_TOPIC/);
});

test("requires https for remote servers and allows plain http only for localhost", async () => {
  assert.equal(
    buildTopicUrl("https://ntfy.example.test/base", "pi"),
    "https://ntfy.example.test/base/pi",
  );
  assert.equal(buildTopicUrl("http://localhost", "pi"), "http://localhost/pi");
  assert.equal(buildTopicUrl("http://127.0.0.1:8080", "pi"), "http://127.0.0.1:8080/pi");
  assert.throws(() => buildTopicUrl("http://ntfy.example.test", "pi"), /requires an https/);
  await assert.rejects(
    publishNtfy(
      { server: "http://ntfy.example.test", topic: "pi", timeoutMs: 1000 },
      buildNotification(),
      async () => assert.fail("insecure remote request must not be sent"),
    ),
    /requires an https/,
  );
});

test("publishes the expected ntfy request with bearer auth", async () => {
  let captured;
  const fetchImpl = async (url, options) => {
    captured = { url, options };
    return { ok: true, status: 200, text: async () => "" };
  };
  const config = {
    server: "https://ntfy.example.test",
    topic: "pi",
    token: "tk_test",
    timeoutMs: 1000,
  };
  const notification = buildNotification({ forceKind: "action" });

  const result = await publishNtfy(config, notification, fetchImpl);

  assert.equal(result.status, 200);
  assert.equal(captured.url, "https://ntfy.example.test/");
  assert.equal(captured.options.method, "POST");
  assert.equal(captured.options.headers["Content-Type"], "application/json; charset=utf-8");
  assert.equal(captured.options.headers.Authorization, "Bearer tk_test");
  assert.deepEqual(JSON.parse(captured.options.body), {
    topic: "pi",
    title: "Pi needs attention",
    message: notification.body,
    priority: 4,
    tags: ["robot", "warning"],
  });
});

test("publishes Unicode notification titles without ByteString headers", async () => {
  const notification = buildNotification({
    forceKind: "complete",
    sessionName: "reviewer — café 🧪",
  });
  let payload;
  const fetchImpl = async (_url, options) => {
    assert.doesNotThrow(() => new Headers(options.headers));
    payload = JSON.parse(options.body);
    return { ok: true, status: 200, text: async () => "" };
  };

  await publishNtfy(
    { server: "https://ntfy.example.test", topic: "pi", timeoutMs: 1000 },
    notification,
    fetchImpl,
  );

  assert.equal(payload.title, "Pi completed — reviewer — café 🧪");
  assert.equal(payload.message, notification.body);
});

test("surfaces ntfy HTTP failures and protects bearer tokens", async () => {
  const fetchImpl = async () => ({ ok: false, status: 403, text: async () => "forbidden" });
  await assert.rejects(
    publishNtfy(
      { server: "https://ntfy.example.test", topic: "pi", timeoutMs: 1000 },
      buildNotification(),
      fetchImpl,
    ),
    /HTTP 403: forbidden/,
  );
});

test("extension treats a successful terminal tool result as complete and notifies once", async () => {
  const handlers = new Map();
  const commands = new Map();
  ntfyNotifier({
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand(name, definition) {
      commands.set(name, definition);
    },
  });

  const branch = [
    {
      type: "message",
      message: {
        role: "assistant",
        content: [{ type: "toolCall", id: "call-1", name: "final_output", arguments: {} }],
        stopReason: "toolUse",
      },
    },
    {
      type: "message",
      message: {
        role: "toolResult",
        toolCallId: "call-1",
        toolName: "final_output",
        content: [{ type: "text", text: "ok" }],
        isError: false,
      },
    },
  ];
  const ctx = {
    cwd: "/root/project",
    hasUI: false,
    sessionManager: {
      getBranch: () => branch,
      getSessionName: () => undefined,
    },
  };

  const previousFetch = globalThis.fetch;
  const previousServer = process.env.PI_NTFY_SERVER;
  const previousTopic = process.env.PI_NTFY_TOPIC;
  const requests = [];
  process.env.PI_NTFY_SERVER = "https://ntfy.example.test";
  process.env.PI_NTFY_TOPIC = "pi";
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options });
    return { ok: true, status: 200, text: async () => "" };
  };
  try {
    await handlers.get("agent_start")({ type: "agent_start" }, ctx);
    await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
    await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
  } finally {
    globalThis.fetch = previousFetch;
    if (previousServer === undefined) delete process.env.PI_NTFY_SERVER;
    else process.env.PI_NTFY_SERVER = previousServer;
    if (previousTopic === undefined) delete process.env.PI_NTFY_TOPIC;
    else process.env.PI_NTFY_TOPIC = previousTopic;
  }

  assert.equal(commands.has("ntfy-test"), true);
  assert.equal(requests.length, 1);
  const payload = JSON.parse(requests[0].options.body);
  assert.equal(payload.topic, "pi");
  assert.equal(payload.title, "Pi completed — project");
  assert.equal(payload.priority, 3);
});
