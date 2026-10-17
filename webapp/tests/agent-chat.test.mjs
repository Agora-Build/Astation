import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  Conversation,
  activity,
  safeLink,
  importSessionKey,
  signedFrame,
  verifiedBody,
  base64,
  encodeFields,
  validPrompt,
  messageText,
  timestamp,
} from "../agent/chat-core.mjs";

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

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../../Tests/AstationTests/Fixtures/agent-chat-v1.json",
      import.meta.url,
    ),
  ),
);
const textPart = (id, markdown) => ({ id, kind: "text", markdown });
function connected(state = "ready") {
  let time = 1000;
  const conversation = new Conversation(() => time);
  let sequence = 0;
  let conv = "c";
  const context = (extra = {}) =>
    conversation.receive({
      op: "context",
      connected: true,
      supported: true,
      enabled: true,
      agentId: "a",
      conversationId: conv,
      opening: true,
      ...extra,
    });
  context();
  const opened = (extra = {}) =>
    conversation.receive({
      op: "event",
      event: {
        v: 1,
        op: "opened",
        agentId: "a",
        conversationId: conv,
        generation: "g",
        sequence: 0,
        status: { state, since: time },
        ...extra,
      },
    });
  opened();
  return {
    conversation,
    advance: (ms) => {
      time += ms;
    },
    reopen(before, extra = {}) {
      conv += "x";
      sequence = 0;
      context({ before, ...extra });
      opened();
    },
    event(op, data = {}) {
      const defaults =
        op === "message"
          ? {
              messageId: "m",
              role: "assistant",
              turnId: "t",
              createdAt: time,
              parts: [textPart("p1", "Hello")],
            }
          : op === "status"
            ? { state: "ready", since: time }
            : op === "complete"
              ? { turnId: "t", outcome: "done" }
              : {};
      conversation.receive({
        op: "event",
        event: {
          v: 1,
          op,
          agentId: "a",
          conversationId: conv,
          generation: "g",
          sequence: ++sequence,
          ...defaults,
          ...data,
        },
      });
    },
  };
}

test("published host shapes cover history, local prompts, optimistic reconciliation, tools and late content", () => {
  const c = new Conversation(() => 1700000001000);
  c.receive({
    op: "context",
    connected: true,
    supported: true,
    enabled: true,
    opening: true,
    conversationId: "fixture-conversation",
    agentId: "fixture-agent",
  });
  for (const event of fixture.events) {
    if (event.op === "accepted")
      assert(c.addPrompt(fixture.requestId, "Reply with a harmless greeting"));
    c.receive({ op: "event", event });
  }
  assert.equal(c.messages.length, 4);
  assert.equal(c.messages[0].origin, "local");
  assert.equal(c.messages[0].outcome, "interrupted");
  assert.equal(c.messages[2].id, "remote-user");
  assert.equal(c.messages[2].delivery, "delivered");
  assert.equal(c.messages[3].parts.length, 3);
  assert.equal(c.messages[3].parts[1].kind, "tool");
  assert.equal(c.messages[3].outcome, "done");
  assert.match(messageText(c.messages[3]), /Late transcript/);
  assert(c.canSend);
});

test("parts deduplicate by ID and whole history replaces content without duplicate bubbles", () => {
  const { conversation: c, event, reopen } = connected();
  event("message");
  event("delta", { messageId: "m", part: textPart("p2", "Next") });
  event("delta", { messageId: "m", part: textPart("p2", "Ignored") });
  assert.equal(c.messages[0].parts.length, 2);
  reopen();
  event("message", {
    history: true,
    parts: [textPart("p1", "Replaced"), textPart("p2", "Whole")],
  });
  assert.equal(c.messages.length, 1);
  assert.equal(messageText(c.messages[0]), "Replaced\n\nWhole");
});

test("live transcript echo waits for acceptance and a disconnect preserves confirmed delivery", () => {
  const { conversation: c, event } = connected();
  c.addPrompt("r", "Hello");
  event("message", {
    messageId: "user",
    role: "user",
    origin: "remote",
    requestId: "r",
    parts: [textPart("text", "Hello")],
  });
  assert.equal(c.messages[0].delivery, "sending");
  event("accepted", { requestId: "r" });
  c.disconnect();
  assert.equal(c.messages[0].delivery, "delivered");
  assert(!c.canSend);
  assert.equal(c.messages.length, 1);
});

test("older history pages insert before the requested anchor in host order", () => {
  const { conversation: c, event, reopen } = connected();
  event("message", { messageId: "latest" });
  reopen("latest");
  event("message", { messageId: "old-1", history: true });
  event("message", { messageId: "old-2", history: true });
  assert.deepEqual(
    c.messages.map((m) => m.id),
    ["old-1", "old-2", "latest"],
  );
  assert.equal(c.oldestMessageId, "old-1");
});

test("only fresh Ready enables submission; heartbeat preserves the original since", () => {
  const { conversation: c, event, advance } = connected("unknown");
  assert(!c.canSend);
  for (const state of ["working", "waiting", "unknown"]) {
    event("status", { state });
    assert(!c.canSend);
  }
  event("status", { state: "ready", since: 1000 });
  assert(c.canSend);
  advance(31000);
  assert(!c.canSend);
  event("status", { state: "ready", since: 1000 });
  assert.equal(c.since, 1000);
  assert(c.canSend);
});

test("execution completion accepts local turns without request IDs and late reply parts", () => {
  const { conversation: c, event } = connected();
  c.addPrompt("r", "Hello");
  event("accepted", { requestId: "r" });
  event("status", { state: "working" });
  event("message", { requestId: "r" });
  event("complete", { requestId: "r", outcome: "interrupted" });
  event("delta", { messageId: "m", part: textPart("late", "Still valid") });
  assert.equal(c.messages[1].outcome, "interrupted");
  assert.equal(c.messages[1].parts.length, 2);
  assert(!c.canSend, "completion does not invent Ready");
  event("status");
  assert(c.canSend);
  assert(!c.addPrompt("r", "Duplicate"));
});

test("refusals differ from errors after acceptance and unknown delivery never retries", () => {
  for (const accepted of [false, true]) {
    const { conversation: c, event } = connected();
    c.addPrompt("r", "Try");
    if (accepted) event("accepted", { requestId: "r" });
    event("error", { requestId: "r", text: "The terminal has unsent input" });
    assert.equal(c.messages[0].delivery, accepted ? "delivered" : "refused");
    assert(c.canSend);
  }
  const { conversation: c, event, reopen } = connected();
  c.addPrompt("r", "Maybe delivered");
  event("error", {
    requestId: "r",
    text: "delivery unknown; check the terminal",
  });
  assert.equal(c.messages[0].delivery, "unknown");
  assert(!c.canSend);
  reopen();
  assert(!c.canSend);
  assert.equal(c.messages.length, 1, "reopen creates no outgoing prompt");
});

test("pre-session errors and headerless close are bound to the selected conversation", () => {
  const c = new Conversation();
  c.receive({
    op: "context",
    conversationId: "c",
    agentId: "a",
    connected: true,
    supported: true,
    enabled: true,
    opening: true,
  });
  c.receive({
    op: "event",
    event: {
      v: 1,
      op: "error",
      conversationId: "wrong",
      agentId: "a",
      text: "Forged",
    },
  });
  assert.notEqual(c.notice, "Forged");
  c.receive({
    op: "event",
    event: {
      v: 1,
      op: "error",
      conversationId: "c",
      agentId: "a",
      text: "Chat unavailable",
    },
  });
  assert.equal(c.notice, "Chat unavailable");
  assert(!c.canSend);
  const { conversation: open } = connected();
  open.receive({
    op: "event",
    event: { v: 1, op: "close", agentId: "a", conversationId: "c" },
  });
  assert(open.closed);
  assert(!open.canSend);
});

test("sequence gaps stop sending, while explicit reopen resets only the view sequence", () => {
  const { conversation: c, event, reopen } = connected();
  event("message");
  event("delta", {
    sequence: 1,
    messageId: "m",
    part: textPart("duplicate", "No"),
  });
  assert.equal(c.messages[0].parts.length, 1);
  event("status", { sequence: 3 });
  assert(!c.canSend);
  reopen();
  assert(c.canSend);
  assert.equal(c.lastSequence, 0);
  event("status", { generation: "other" });
  assert(!c.canSend);
  assert.match(c.notice, /process changed/);
});

test("reload and disconnect preserve uncertain delivery without inventing requests", () => {
  const { conversation: c } = connected();
  c.addPrompt("r", "Maybe delivered");
  c.disconnect();
  assert.equal(c.messages[0].delivery, "unknown");
  const reloaded = new Conversation();
  reloaded.receive({
    op: "context",
    connected: true,
    supported: true,
    enabled: false,
    opening: true,
    conversationId: "new",
    pending: true,
    pendingRequestId: "r",
    deliveryUnknown: true,
  });
  assert.equal(reloaded.messages.length, 0);
  assert.equal(reloaded.activeRequest, "r");
  assert(!reloaded.canSend);
});

test("prompt validation matches host byte, control and command rules", () => {
  for (const text of [
    "",
    " ",
    "\x1b[201~bad",
    "bad\r",
    "\u0085",
    " /resume",
    "\n !echo test",
    "\u00e9".repeat(16385),
  ])
    assert(!validPrompt(text));
  for (const text of [
    "# hello",
    "say /help",
    "line\nnext\tcolumn",
    "\u00e9".repeat(16384),
    "emoji \u200d ok",
  ])
    assert(validPrompt(text));
});

test("message and transcript limits include tools but allow the host truncation marker", () => {
  const { conversation: c, event } = connected();
  event("message", {
    parts: [
      textPart("p1", "x".repeat(131072)),
      textPart("atem:truncated", "\u2026 (truncated)"),
    ],
  });
  assert(c.canSend);
  event("delta", {
    messageId: "m",
    part: { id: "overflow", kind: "tool", name: "Read", summary: "README" },
  });
  assert(!c.canSend);
  const bounded = connected();
  for (let i = 0; i < 513; i++)
    bounded.event("message", { messageId: `m${i}` });
  assert.equal(bounded.conversation.messages.length, 512);
  assert(!bounded.conversation.canSend);
});

test("timestamps accept published Unix milliseconds and RFC3339, rejecting malformed values", () => {
  assert.equal(timestamp(1700000000000), 1700000000000);
  assert.equal(timestamp("2023-11-14T22:13:20.000Z"), 1700000000000);
  for (const value of [null, {}, Infinity, -1, "invalid", "1700000000000"])
    assert.equal(timestamp(value), null);
});

test("part metadata is bounded even when every content field is empty", () => {
  const { conversation: c, event } = connected();
  const parts = Array.from({ length: 2048 }, (_, i) =>
    textPart("p".repeat(120) + i, ""),
  );
  for (let i = 0; i < 60; i++)
    event("message", { messageId: `metadata-${i}`, parts });
  assert(!c.canSend);
  assert(c.messages.length < 60);
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
