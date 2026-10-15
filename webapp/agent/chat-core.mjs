export const MAX_PROMPT_BYTES = 32768;
export const MAX_MESSAGE_BYTES = 131072;
export const ACTIVITY_TTL_MS = 30000;
export const MAX_TRANSCRIPT_BYTES = 8388608;
export const MAX_SERIALIZED_BYTES = 16777216;
export const MAX_FRAME_BYTES = 1500000;
export const MAX_MESSAGES = 512;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function base64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function unbase64(value, limit = MAX_FRAME_BYTES) {
  if (
    typeof value !== "string" ||
    value.length > limit ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(value)
  )
    throw new Error("Invalid frame");
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

export function encodeFields(fields) {
  const values = fields.map((value) => encoder.encode(value));
  const bytes = new Uint8Array(
    values.reduce((size, value) => size + 4 + value.length, 0),
  );
  const view = new DataView(bytes.buffer);
  let offset = 0;
  for (const value of values) {
    view.setUint32(offset, value.length);
    bytes.set(value, offset + 4);
    offset += 4 + value.length;
  }
  return bytes;
}

export async function importSessionKey(secret, cryptoAPI = globalThis.crypto) {
  const raw = secret.replace(/-/g, "+").replace(/_/g, "/");
  const bytes = unbase64(raw.padEnd(Math.ceil(raw.length / 4) * 4, "="), 64);
  if (bytes.length !== 32) throw new Error("Invalid session key");
  return cryptoAPI.subtle.importKey(
    "raw",
    bytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function signingBytes(direction, frame) {
  return encodeFields([
    `astation-browser-chat-${direction}-v1`,
    frame.sessionId,
    frame.nonce,
    String(frame.sequence),
    frame.body,
  ]);
}

export async function signedFrame(
  key,
  sessionId,
  nonce,
  sequence,
  body,
  cryptoAPI = globalThis.crypto,
) {
  const frame = {
    sessionId,
    nonce,
    sequence,
    body: base64(encoder.encode(JSON.stringify(body))),
  };
  frame.mac = base64(
    new Uint8Array(
      await cryptoAPI.subtle.sign("HMAC", key, signingBytes("request", frame)),
    ),
  );
  return { type: "browserChat", data: frame };
}

export async function verifiedBody(
  key,
  frame,
  sessionId,
  nonce,
  lastSequence,
  cryptoAPI = globalThis.crypto,
) {
  if (
    !frame ||
    frame.sessionId !== sessionId ||
    frame.nonce !== nonce ||
    !Number.isSafeInteger(frame.sequence) ||
    frame.sequence <= lastSequence ||
    typeof frame.body !== "string" ||
    frame.body.length > MAX_FRAME_BYTES
  )
    return null;
  try {
    if (
      !(await cryptoAPI.subtle.verify(
        "HMAC",
        key,
        unbase64(frame.mac, 64),
        signingBytes("response", frame),
      ))
    )
      return null;
    return JSON.parse(decoder.decode(unbase64(frame.body)));
  } catch {
    return null;
  }
}

export function safeLink(value) {
  try {
    const url = new URL(value);
    return ["https:", "http:"].includes(url.protocol) &&
      !url.username &&
      !url.password
      ? url.href
      : null;
  } catch {
    return null;
  }
}

export function activity(state, lastUpdate, connected, now = Date.now()) {
  if (!connected) return { state: "offline", label: "Offline" };
  if (!lastUpdate || now - lastUpdate > ACTIVITY_TTL_MS)
    return { state: "unknown", label: "Unknown" };
  return (
    {
      ready: { state: "ready", label: "Ready" },
      working: { state: "working", label: "Working" },
      waiting: { state: "waiting", label: "Needs your input" },
    }[state] || { state: "unknown", label: "Unknown" }
  );
}

export function timestamp(value) {
  const number =
    typeof value === "number"
      ? value
      : typeof value === "string" && /^\d{4}-\d\d-\d\dT/.test(value)
        ? Date.parse(value)
        : NaN;
  return Number.isFinite(number) && number >= 0 && number <= 8640000000000000
    ? number
    : null;
}

export function validPrompt(text) {
  return (
    typeof text === "string" &&
    Boolean(text.trim()) &&
    encoder.encode(text).length <= MAX_PROMPT_BYTES &&
    !/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/.test(text) &&
    !/^[\s]*[!/]/u.test(text)
  );
}

const identifier = (value) =>
  typeof value === "string" &&
  value.length > 0 &&
  encoder.encode(value).length <= 128;
const states = ["ready", "working", "waiting", "unknown"];
const validStatus = (status) =>
  status &&
  states.includes(status.state) &&
  timestamp(status.since) !== null &&
  (status.detail === undefined ||
    (typeof status.detail === "string" &&
      encoder.encode(status.detail).length <= 4096));
const validPart = (part) =>
  part &&
  identifier(part.id) &&
  ((part.kind === "text" && typeof part.markdown === "string") ||
    (part.kind === "tool" &&
      typeof part.name === "string" &&
      typeof part.summary === "string"));
const partBytes = (part) =>
  part.id === "atem:truncated" &&
  part.kind === "text" &&
  part.markdown === "\u2026 (truncated)"
    ? 0
    : encoder.encode(
        part.kind === "text" ? part.markdown : part.name + part.summary,
      ).length;
export const messageText = (message) =>
  message.parts
    .map((part) =>
      part.kind === "text"
        ? part.markdown
        : `${part.name}${part.summary ? `: ${part.summary}` : ""}`,
    )
    .join("\n\n");

export class Conversation {
  constructor(now = () => Date.now()) {
    this.now = now;
    this.messages = [];
    this.context = {
      agentName: "Your code agent",
      hostname: "Your Astation",
      connected: false,
      enabled: false,
    };
    this.state = "unknown";
    this.since = null;
    this.detail = "";
    this.activityAt = 0;
    this.activeRequest = null;
    this.lastSequence = 0;
    this.generation = null;
    this.notice = "";
    this.uncertain = false;
    this.closed = true;
    this.opening = false;
    this.pageBefore = null;
    this.turns = new Map();
    this.requestIds = new Set();
  }

  get canSend() {
    return (
      this.context.connected &&
      this.context.enabled &&
      Boolean(this.generation) &&
      !this.closed &&
      !this.opening &&
      !this.activeRequest &&
      !this.uncertain &&
      activity(this.state, this.activityAt, true, this.now()).state === "ready"
    );
  }

  get oldestMessageId() {
    return this.messages.find((message) => !message.optimistic)?.id;
  }

  addPrompt(id, text) {
    if (!this.canSend || !identifier(id) || this.requestIds.has(id))
      return false;
    if (!validPrompt(text)) {
      this.notice =
        "Use a text prompt up to 32 KiB. Commands (/), shell mode (!) and control characters are unavailable in chat.";
      return false;
    }
    if (!this.withinLimits([{ id: "prompt", kind: "text", markdown: text }])) {
      this.disconnect(
        "This conversation reached its size limit. Open a new session from Astation.",
      );
      return false;
    }
    this.requestIds.add(id);
    this.notice = "";
    this.messages.push({
      id,
      requestId: id,
      role: "user",
      origin: "remote",
      optimistic: true,
      parts: [{ id: "prompt", kind: "text", markdown: text }],
      delivery: "sending",
      at: this.now(),
    });
    this.activeRequest = id;
    return true;
  }

  receive(body) {
    if (!body || typeof body !== "object") return;
    if (body.op === "context") {
      if (
        body.conversationId &&
        body.conversationId !== this.context.conversationId
      ) {
        this.opening = true;
        this.closed = true;
        this.lastSequence = 0;
        this.pageBefore = body.before || null;
      }
      this.context = { ...this.context, ...body };
      this.opening = Boolean(body.opening);
      if (typeof body.closed === "boolean") this.closed = body.closed;
      if (body.pendingRequestId) this.activeRequest = body.pendingRequestId;
      else if (body.pending === false) this.activeRequest = null;
      if (typeof body.deliveryUnknown === "boolean")
        this.uncertain = body.deliveryUnknown;
      this.notice = body.notice || "";
      if (!body.connected) this.disconnect(this.notice || undefined);
      return;
    }
    if (body.op === "notice") {
      this.notice = body.text || "";
      if (body.blocked) this.uncertain = true;
      if (body.requestId)
        this.updateDelivery(body.requestId, body.delivery || "unknown");
      if (body.requestId === this.activeRequest) {
        if (body.delivery === "failed") this.activeRequest = null;
        else if (body.delivery === "unknown") this.uncertain = true;
      }
      return;
    }
    if (body.op !== "event") return;
    const event = body.event;
    if (
      !event ||
      event.v !== 1 ||
      (this.context.conversationId &&
        event.conversationId !== this.context.conversationId) ||
      (this.context.agentId && event.agentId !== this.context.agentId)
    )
      return;
    if (
      event.op === "close" &&
      event.generation === undefined &&
      event.sequence === undefined
    ) {
      this.closed = true;
      this.opening = false;
      this.state = "unknown";
      this.notice ||=
        "The host closed this conversation. Reopen the view to load history.";
      if (this.activeRequest) {
        this.updateDelivery(this.activeRequest, "unknown");
        this.uncertain = true;
      }
      return;
    }
    if (
      event.op === "error" &&
      event.generation === undefined &&
      event.sequence === undefined &&
      this.opening
    ) {
      this.notice = event.text || "Chat is unavailable.";
      this.closed = true;
      this.opening = false;
      return;
    }
    if (event.op === "opened") {
      if (
        !this.opening ||
        event.sequence !== 0 ||
        !identifier(event.generation) ||
        !validStatus(event.status)
      )
        return;
      if (this.generation && this.generation !== event.generation) {
        this.disconnect(
          "The agent process changed. Open a new browser session from Astation.",
        );
        return;
      }
      this.generation = event.generation;
      this.lastSequence = 0;
      this.opening = false;
      this.closed = false;
      this.setStatus(event.status);
      return;
    }
    if (
      this.closed ||
      this.opening ||
      !this.generation ||
      !Number.isSafeInteger(event.sequence)
    )
      return;
    if (event.generation !== this.generation) {
      this.disconnect(
        "The agent process changed. Open a new browser session from Astation.",
      );
      return;
    }
    if (event.sequence <= this.lastSequence) return;
    if (event.sequence !== this.lastSequence + 1) {
      this.closed = true;
      this.notice =
        "Some conversation events are missing. Reopen the view; prompts are never resent.";
      if (this.activeRequest) this.uncertain = true;
      return;
    }
    this.lastSequence = event.sequence;
    switch (event.op) {
      case "accepted":
        this.updateDelivery(event.requestId, "delivered");
        if (event.requestId === this.activeRequest) this.uncertain = false;
        break;
      case "message":
        this.mergeMessage(event);
        break;
      case "delta": {
        const message = this.messages.find(
          (item) => item.id === event.messageId && !item.optimistic,
        );
        if (!message || !validPart(event.part)) {
          this.invalid();
          break;
        }
        if (message.parts.some((part) => part.id === event.part.id)) break;
        const parts = [...message.parts, event.part];
        if (!this.withinLimits(parts, message)) {
          this.invalid();
          break;
        }
        message.parts = parts;
        break;
      }
      case "status":
        if (validStatus(event)) this.setStatus(event);
        else this.invalid();
        break;
      case "complete":
        if (
          !identifier(event.turnId) ||
          !["done", "interrupted"].includes(event.outcome)
        ) {
          this.invalid();
          break;
        }
        this.turns.set(event.turnId, event.outcome);
        if (this.turns.size > 1024)
          this.turns.delete(this.turns.keys().next().value);
        for (const message of this.messages)
          if (message.turnId === event.turnId) message.outcome = event.outcome;
        if (event.requestId === this.activeRequest) {
          this.updateDelivery(event.requestId, "delivered");
          this.activeRequest = null;
          this.uncertain = false;
        }
        break;
      case "error": {
        this.notice = event.text || "The agent could not complete the request.";
        if (event.requestId === this.activeRequest) {
          const message = this.messages.find(
            (item) =>
              item.requestId === event.requestId && item.role === "user",
          );
          const unknown = /delivery unknown/i.test(this.notice);
          this.updateDelivery(
            event.requestId,
            unknown
              ? "unknown"
              : message?.delivery === "delivered"
                ? "delivered"
                : "refused",
          );
          this.uncertain = unknown;
          this.activeRequest = null;
        }
        break;
      }
    }
  }

  setStatus(status) {
    this.state = status.state;
    this.since = timestamp(status.since);
    this.detail = status.detail || "";
    this.activityAt = this.now();
  }

  mergeMessage(event) {
    if (
      !identifier(event.messageId) ||
      !["user", "assistant"].includes(event.role) ||
      !identifier(event.turnId) ||
      timestamp(event.createdAt) === null ||
      (event.role === "user" && !["local", "remote"].includes(event.origin)) ||
      !Array.isArray(event.parts) ||
      !event.parts.every(validPart) ||
      new Set(event.parts.map((part) => part.id)).size !== event.parts.length
    ) {
      this.invalid();
      return;
    }
    let message = this.messages.find(
      (item) => item.id === event.messageId && !item.optimistic,
    );
    if (
      message &&
      (message.role !== event.role || message.turnId !== event.turnId)
    ) {
      this.invalid();
      return;
    }
    const optimistic =
      event.role === "user" && event.origin === "remote" && event.requestId
        ? this.messages.find(
            (item) => item.optimistic && item.requestId === event.requestId,
          )
        : null;
    const replacement = message || optimistic;
    if (!this.withinLimits(event.parts, replacement)) {
      this.invalid();
      return;
    }
    const updated = {
      id: event.messageId,
      role: event.role,
      origin: event.origin,
      turnId: event.turnId,
      requestId: event.requestId,
      parts: event.parts,
      at: timestamp(event.createdAt),
      outcome: this.turns.get(event.turnId),
      history: event.history === true,
      delivery:
        event.role === "user" && event.origin === "remote"
          ? event.history
            ? "delivered"
            : replacement?.delivery || "remote"
          : undefined,
    };
    if (replacement) Object.assign(replacement, updated, { optimistic: false });
    else {
      const anchor =
        event.history && this.pageBefore
          ? this.messages.findIndex((item) => item.id === this.pageBefore)
          : -1;
      if (anchor >= 0) this.messages.splice(anchor, 0, updated);
      else this.messages.push(updated);
    }
    if (optimistic && message && optimistic !== message)
      this.messages.splice(this.messages.indexOf(optimistic), 1);
    if (
      event.history &&
      event.role === "user" &&
      event.origin === "remote" &&
      event.requestId === this.activeRequest
    ) {
      this.uncertain = false;
    }
  }

  updateDelivery(id, delivery) {
    const message = this.messages.find(
      (item) => item.requestId === id && item.role === "user",
    );
    if (
      message &&
      !(delivery === "unknown" && message.delivery === "delivered")
    )
      message.delivery = delivery;
  }

  withinLimits(parts, replacement) {
    // Empty parts still consume memory through IDs, metadata and JSON escaping.
    const serializedBytes =
      this.messages.reduce(
        (total, item) =>
          total +
          (item === replacement
            ? 0
            : encoder.encode(JSON.stringify(item)).length),
        0,
      ) + encoder.encode(JSON.stringify({ ...replacement, parts })).length;
    const bytes = this.messages.reduce(
      (total, item) =>
        total +
        (item === replacement
          ? 0
          : item.parts.reduce((sum, part) => sum + partBytes(part), 0)),
      0,
    );
    const size = parts.reduce((sum, part) => sum + partBytes(part), 0);
    return (
      parts.length <= 4096 &&
      size <= MAX_MESSAGE_BYTES &&
      bytes + size <= MAX_TRANSCRIPT_BYTES &&
      serializedBytes <= MAX_SERIALIZED_BYTES &&
      (replacement || this.messages.length < MAX_MESSAGES)
    );
  }

  invalid() {
    this.disconnect(
      "The agent sent invalid or oversized conversation data. Reopen from Astation or use Open Terminal.",
    );
  }

  disconnect(
    reason = "Connection lost. Reopen this agent from Astation to reconnect.",
  ) {
    this.context.connected = false;
    this.uncertain = true;
    this.closed = true;
    this.state = "unknown";
    this.notice = reason;
    if (this.activeRequest) this.updateDelivery(this.activeRequest, "unknown");
  }
}
