import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import {
  Conversation,
  activity,
  safeLink,
  importSessionKey,
  signedFrame,
  verifiedBody,
  base64,
  encodeFields,
  markdownBlocks,
} from "../chat/chat-core.mjs";

const secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const session = "test-session";
const nonce = "test-nonce";
const body = "eyJvcCI6Im9wZW4ifQ==";
const responseMAC = "xrk7NVzgDUxvcJ45X+FWsW2Rjg7xDY4xFq3v37xTNWY=";

test("browser request and response MACs match independent Swift/Python vectors", async () => {
  const key = await importSessionKey(secret, webcrypto);
  const request = await signedFrame(
    key,
    session,
    nonce,
    1,
    { op: "open" },
    webcrypto,
  );
  assert.deepEqual(request, {
    type: "browserChat",
    data: {
      sessionId: session,
      nonce,
      sequence: 1,
      body,
      mac: "TNBvyVK7GHmiZIA5L3gZe9NzZyELeIyGC3hlntDA56Y=",
    },
  });
  const response = { ...request.data, mac: responseMAC };
  assert.deepEqual(
    await verifiedBody(key, response, session, nonce, 0, webcrypto),
    { op: "open" },
  );
  assert.equal(
    await verifiedBody(key, request.data, session, nonce, 0, webcrypto),
    null,
    "request is not a response",
  );
  for (const change of [
    { body: base64(new TextEncoder().encode('{"op":"submit"}')) },
    { nonce: "wrong" },
    { sessionId: "wrong" },
    { sequence: 2 },
    { mac: "!!!!" },
  ]) {
    assert.equal(
      await verifiedBody(
        key,
        { ...response, ...change },
        session,
        nonce,
        0,
        webcrypto,
      ),
      null,
    );
  }
  assert.equal(
    await verifiedBody(key, response, session, nonce, 1, webcrypto),
    null,
    "reject replay",
  );
  assert.equal(
    await verifiedBody(
      key,
      { ...response, sequence: Number.MAX_SAFE_INTEGER + 1 },
      session,
      nonce,
      0,
      webcrypto,
    ),
    null,
  );
  await assert.rejects(importSessionKey("bad", webcrypto));
});

test("length framing counts UTF-8 bytes, including non-ASCII input", () => {
  assert.deepEqual(
    [...encodeFields(["a", "\u00e9"])],
    [0, 0, 0, 1, 97, 0, 0, 0, 2, 195, 169],
  );
});

test("fenced Markdown preserves all code lines, closing fences and incomplete streams", () => {
  const text = "Before\n```js\nconst value = {\n  ready: true\n};\n```\nAfter";
  assert.deepEqual(markdownBlocks(text), [
    { type: "text", language: null, text: "Before" },
    {
      type: "code",
      language: "js",
      text: "const value = {\n  ready: true\n};",
    },
    { type: "text", language: null, text: "After" },
  ]);
  assert.deepEqual(markdownBlocks("```js\nconst partial"), [
    { type: "code", language: "js", text: "const partial" },
  ]);
});

test("a provider error describes the task outcome without claiming the prompt was undelivered", () => {
  const { conversation: c, event } = connected();
  c.addPrompt("r", "Try this");
  event("accepted", { requestId: "r" });
  event("error", { requestId: "r", text: "The task failed" });
  assert.equal(c.messages[0].delivery, "delivered");
  assert.equal(c.notice, "The task failed");
  assert(c.canSend);
});

function connected() {
  let time = 1000;
  const conversation = new Conversation(() => time);
  conversation.receive({
    op: "context",
    connected: true,
    supported: true,
    enabled: true,
    generation: "g",
  });
  let sequence = 0;
  return {
    conversation,
    advance: (ms) => {
      time += ms;
    },
    event(op, data = {}) {
      conversation.receive({
        op: "event",
        event: { v: 1, op, generation: "g", sequence: ++sequence, ...data },
      });
    },
  };
}

test("prompts have delivery boundaries and completion requires an explicit event", () => {
  const { conversation: c, event, advance } = connected();
  assert(c.canSend);
  assert(c.addPrompt("r", "Fix this"));
  assert(!c.canSend);
  assert.equal(c.messages[0].delivery, "sending");
  event("accepted", { requestId: "r" });
  assert.equal(c.messages[0].delivery, "delivered");
  assert.equal(c.state, "unknown", "acceptance does not invent working status");
  event("status", { state: "working" });
  event("message", { messageId: "m", text: "First" });
  event("delta", { messageId: "m", text: " reply" });
  assert.equal(c.messages[1].text, "First reply");
  advance(120000);
  assert(!c.canSend, "silence cannot imply completion");
  assert.equal(activity(c.state, c.activityAt, true, c.now()).state, "unknown");
  event("complete", { requestId: "r" });
  assert(c.canSend);
  assert(!c.addPrompt("r", "duplicate"));
});

test("duplicates and wrong generations are ignored; gaps permanently disable sending", () => {
  const { conversation: c, event } = connected();
  event("message", { messageId: "m", text: "Reply" });
  c.receive({
    op: "event",
    event: {
      v: 1,
      op: "delta",
      generation: "g",
      sequence: 1,
      messageId: "m",
      text: "duplicate",
    },
  });
  event("status", { generation: "wrong", state: "ready" });
  assert.equal(c.messages[0].text, "Reply");
  assert.equal(c.state, "unknown");
  event("status", { state: "ready" });
  assert(!c.canSend);
  c.receive({ op: "context", connected: true, enabled: true });
  assert(!c.canSend, "periodic context does not recover missing events");
});

test("unknown delivery, reconnects and page reload never resend prompts", () => {
  const { conversation: c } = connected();
  c.addPrompt("r", "Possibly delivered");
  c.disconnect();
  assert.equal(c.messages[0].delivery, "unknown");
  c.receive({ op: "context", connected: true, enabled: true });
  assert(!c.canSend);
  const reloaded = new Conversation();
  reloaded.receive({
    op: "context",
    connected: true,
    enabled: true,
    generation: "g",
    lastSequence: 7,
    pending: true,
  });
  assert.equal(reloaded.lastSequence, 7);
  assert.equal(reloaded.messages.length, 0);
  assert(!reloaded.canSend);
});

test("unsupported hosts, failed submissions and byte limits", () => {
  const { conversation: c, event } = connected();
  c.context.enabled = false;
  assert(!c.addPrompt("r", "Unsupported"));
  c.context.enabled = true;
  assert(!c.addPrompt("huge", "\u00e9".repeat(16385)));
  assert(c.addPrompt("r", "Valid"));
  c.receive({
    op: "notice",
    requestId: "r",
    text: "Not delivered",
    delivery: "failed",
  });
  assert(c.canSend);
  assert.equal(c.messages[0].delivery, "failed");
  event("message", { messageId: "m", text: "a".repeat(131072) });
  event("delta", { messageId: "m", text: "b" });
  assert(!c.canSend);
  assert.equal(c.messages[1].text.length, 131072);
});

test("conversation size is bounded across many valid messages", () => {
  const { conversation: c, event } = connected();
  for (let i = 0; i < 513; i++)
    event("message", { messageId: `m${i}`, text: "hello" });
  assert.equal(c.messages.length, 512);
  assert(!c.canSend);
});

test("safe links reject executable protocols and embedded credentials", () => {
  for (const link of [
    "javascript:alert(1)",
    "data:text/html,hello",
    "file:///etc/passwd",
    "https://name:secret@example.com",
    "/relative",
  ])
    assert.equal(safeLink(link), null);
  assert.equal(
    safeLink("https://github.com/Agora-Build/Astation"),
    "https://github.com/Agora-Build/Astation",
  );
});

test("agent freshness and connectivity determine the activity indicator", () => {
  assert.equal(activity("ready", 1000, true, 1001).label, "Ready");
  assert.equal(activity("working", 1000, true, 31001).state, "unknown");
  assert.equal(activity("ready", 1000, false, 1001).state, "offline");
  assert.equal(activity("Idle", 1000, true, 1001).state, "unknown");
});
