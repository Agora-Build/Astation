export const MAX_PROMPT_BYTES = 32768;
export const MAX_MESSAGE_BYTES = 131072;
export const ACTIVITY_TTL_MS = 30000;
export const MAX_TRANSCRIPT_BYTES = 2097152;
export const MAX_MESSAGES = 512;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function base64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function unbase64(value, limit = MAX_MESSAGE_BYTES * 2) {
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
    frame.body.length > MAX_MESSAGE_BYTES * 2
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

export function markdownBlocks(text) {
  const blocks = [];
  let lines = [];
  let language = null;
  const flush = () => {
    if (lines.length || language !== null) {
      blocks.push({
        type: language === null ? "text" : "code",
        language,
        text: lines.join("\n"),
      });
    }
    lines = [];
  };
  for (const line of text.split("\n")) {
    if (language === null) {
      const opening = /^```([^`]*)$/.exec(line);
      if (opening) {
        flush();
        language = opening[1].trim().slice(0, 32) || "code";
      } else lines.push(line);
    } else if (/^```\s*$/.test(line)) {
      flush();
      language = null;
    } else lines.push(line);
  }
  flush();
  return blocks;
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
    this.activityAt = 0;
    this.activeRequest = null;
    this.lastSequence = 0;
    this.generation = null;
    this.notice = "";
    this.uncertain = false;
  }

  get canSend() {
    return (
      this.context.connected &&
      this.context.enabled &&
      Boolean(this.generation) &&
      !this.activeRequest &&
      !this.uncertain
    );
  }

  addPrompt(id, text) {
    if (
      !this.canSend ||
      typeof id !== "string" ||
      !id ||
      this.messages.some((item) => item.id === id && item.role === "user") ||
      typeof text !== "string" ||
      !text.trim() ||
      encoder.encode(text).length > MAX_PROMPT_BYTES
    )
      return false;
    if (!this.withinLimits(text)) {
      this.disconnect(
        "This conversation reached its size limit. Open a new session from Astation.",
      );
      return false;
    }
    this.messages.push({
      id,
      role: "user",
      text,
      delivery: "sending",
      at: this.now(),
    });
    this.activeRequest = id;
    return true;
  }

  receive(body) {
    if (!body || typeof body !== "object") return;
    if (body.op === "context") {
      this.context = { ...this.context, ...body };
      if (
        !this.generation &&
        typeof body.generation === "string" &&
        body.generation
      ) {
        this.generation = body.generation;
        this.lastSequence = Number.isSafeInteger(body.lastSequence)
          ? body.lastSequence
          : 0;
      }
      if (body.pending && !this.activeRequest) this.uncertain = true;
      this.notice = body.notice || "";
      if (!body.connected) this.disconnect(this.notice);
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
    if (!event || event.v !== 1) return;
    if (event.op === "opened") {
      if (
        this.generation ||
        event.sequence !== 0 ||
        typeof event.generation !== "string" ||
        !event.generation
      )
        return;
      this.generation = event.generation;
      this.lastSequence = 0;
      return;
    }
    if (
      !this.generation ||
      event.generation !== this.generation ||
      !Number.isSafeInteger(event.sequence) ||
      event.sequence <= this.lastSequence
    )
      return;
    if (event.sequence !== this.lastSequence + 1) {
      this.disconnect(
        "Some conversation events are missing. Reopen this agent from Astation.",
      );
      return;
    }
    this.lastSequence = event.sequence;
    switch (event.op) {
      case "accepted":
        this.updateDelivery(event.requestId, "delivered");
        break;
      case "message":
      case "delta": {
        if (
          typeof event.messageId !== "string" ||
          !event.messageId ||
          typeof event.text !== "string"
        )
          return;
        let message = this.messages.find(
          (item) => item.id === event.messageId && item.role === "assistant",
        );
        const text =
          event.op === "delta"
            ? (message?.text || "") + event.text
            : event.text;
        if (encoder.encode(text).length > MAX_MESSAGE_BYTES) {
          this.disconnect("The reply exceeded the conversation limit.");
          return;
        }
        if (!this.withinLimits(text, message)) {
          this.disconnect(
            "This conversation reached its size limit. Open a new session from Astation.",
          );
          return;
        }
        if (!message) {
          message = {
            id: event.messageId,
            role: "assistant",
            text: "",
            at: this.now(),
          };
          this.messages.push(message);
        }
        message.text = text;
        break;
      }
      case "status":
        this.state = ["ready", "working", "waiting"].includes(event.state)
          ? event.state
          : "unknown";
        this.activityAt = this.now();
        break;
      case "complete":
        if (event.requestId === this.activeRequest) {
          this.updateDelivery(event.requestId, "delivered");
          this.activeRequest = null;
        }
        break;
      case "error":
        this.notice = event.text || "The agent could not complete the request.";
        if (event.requestId === this.activeRequest) {
          this.updateDelivery(event.requestId, "delivered");
          this.activeRequest = null;
        }
        break;
    }
  }

  updateDelivery(id, delivery) {
    const message = this.messages.find(
      (item) => item.id === id && item.role === "user",
    );
    if (message) message.delivery = delivery;
  }

  withinLimits(text, replacement) {
    const bytes = this.messages.reduce(
      (total, item) =>
        total + (item === replacement ? 0 : encoder.encode(item.text).length),
      0,
    );
    return (
      bytes + encoder.encode(text).length <= MAX_TRANSCRIPT_BYTES &&
      (replacement || this.messages.length < MAX_MESSAGES)
    );
  }

  disconnect(
    reason = "Connection lost. Reopen this agent from Astation to reconnect.",
  ) {
    this.context.connected = false;
    this.uncertain = true;
    this.state = "unknown";
    this.notice = reason;
    if (this.activeRequest) {
      this.updateDelivery(this.activeRequest, "unknown");
      this.uncertain = true;
    }
  }
}
