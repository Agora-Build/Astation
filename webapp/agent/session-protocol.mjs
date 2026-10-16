// Pure r5 protocol state for conformance tests. Live browser enrollment and
// transport remain gated on the joint section 9 security specification.
export const BROWSER_SESSION_ACCESS_ENABLED = false;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const rawNumber = Symbol("raw JSON number");
const uuid = (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const sessionId = (v) => typeof v === "string" && /^ses-[a-z2-7]{12}$/.test(v);
const integer = (v) => Number.isSafeInteger(v) && v >= 0;
const check = (condition) => { if (!condition) throw new Error("Invalid session protocol message"); };
const bytes = (text, maximum) => typeof text === "string" && encoder.encode(text).length <= maximum;
const opaque = (v) => bytes(v, 128) && /^[A-Za-z0-9._:-]+$/.test(v);
const plain = (v) => v !== null && typeof v === "object" && !Array.isArray(v) && !v[rawNumber];

function validUnicode(text) {
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = text.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}

export function canonicalPayload(value) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    check(Number.isSafeInteger(value));
    return JSON.stringify(value);
  }
  if (typeof value === "string") { check(validUnicode(value)); return JSON.stringify(value); }
  if (Array.isArray(value)) return `[${value.map(canonicalPayload).join(",")}]`;
  check(plain(value));
  return `{${Object.keys(value).sort().map((key) => `${canonicalPayload(key)}:${canonicalPayload(value[key])}`).join(",")}}`;
}

export async function payloadDigest(value, cryptoAPI = globalThis.crypto) {
  const hash = new Uint8Array(await cryptoAPI.subtle.digest("SHA-256", encoder.encode(canonicalPayload(value))));
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

// JSON.parse alone loses duplicate keys and the spelling of 1e0/1.0 before
// integer validation. Scan original wire bytes, including relay envelopes.
export function parseSessionJSON(input, { integersOnly = true, maximum = 1048576 } = {}) {
  const text = typeof input === "string" ? input : decoder.decode(input);
  check(bytes(text, maximum));
  let offset = 0;
  const whitespace = () => { while (/[\t\n\r ]/.test(text[offset] ?? "x")) offset++; };
  const consume = (character) => { whitespace(); if (text[offset] !== character) return false; offset++; return true; };
  const string = () => {
    whitespace(); check(text[offset] === '"');
    const start = offset++;
    while (offset < text.length) {
      const character = text[offset++];
      if (character === '"') {
        const result = JSON.parse(text.slice(start, offset));
        check(validUnicode(result));
        return result;
      }
      if (character === "\\") offset++;
    }
    throw new Error("Unterminated JSON string");
  };
  const value = (depth) => {
    whitespace(); check(depth <= 64 && offset < text.length);
    if (consume("{")) {
      const object = Object.create(null);
      if (consume("}")) return object;
      do {
        const key = string();
        check(!Object.hasOwn(object, key) && consume(":"));
        object[key] = value(depth + 1);
        if (consume("}")) return object;
      } while (consume(","));
      throw new Error("Invalid JSON object");
    }
    if (consume("[")) {
      const array = [];
      if (consume("]")) return array;
      do { array.push(value(depth + 1)); if (consume("]")) return array; } while (consume(","));
      throw new Error("Invalid JSON array");
    }
    if (text[offset] === '"') return string();
    for (const [literal, result] of [["true", true], ["false", false], ["null", null]]) {
      if (text.startsWith(literal, offset)) { offset += literal.length; return result; }
    }
    const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.slice(offset));
    check(Boolean(match));
    offset += match[0].length;
    const number = Number(match[0]);
    if (!/[.eE]/.test(match[0]) && Number.isSafeInteger(number)) return number;
    check(!integersOnly);
    return { [rawNumber]: match[0] };
  };
  const result = value(0);
  whitespace(); check(offset === text.length);
  return result;
}

export function validTarget(target) {
  return plain(target) && opaque(target.account_id) && opaque(target.atem_device_id)
    && integer(target.host_trust_gen) && sessionId(target.session_id) && uuid(target.process_gen);
}
function validBinding(binding) {
  return plain(binding) && validTarget(binding.target) && uuid(binding.attachment_gen)
    && (binding.lease_epoch === undefined || integer(binding.lease_epoch));
}
function controller(value) {
  return value === null || (plain(value) && uuid(value.controller_session) && integer(value.lease_epoch));
}
function descriptor(value) {
  check(plain(value) && sessionId(value.session_id) && uuid(value.process_gen) && bytes(value.provider, 128) && value.provider.length > 0
    && bytes(value.cwd_label, 256) && ["running", "exited", "interrupted", "recovery_required", "closed", "removed"].includes(value.state)
    && ["ready", "working", "waiting", "unknown"].includes(value.activity) && integer(value.activity_since)
    && Object.hasOwn(value, "controller") && controller(value.controller) && integer(value.created_at)
    && Array.isArray(value.capabilities) && value.capabilities.length <= 32
    && value.capabilities.every((v) => bytes(v, 128) && v.length > 0));
}
function receipt(value) {
  check(plain(value) && uuid(value.request_id) && validTarget(value.target) && ["prompt", "interrupt", "stop"].includes(value.kind)
    && ["accepted", "executing", "completed", "rejected", "outcome_unknown"].includes(value.state)
    && integer(value.updated_at) && (value.detail === undefined || bytes(value.detail, 512)));
}

export function decodeSessionPacket(input) {
  const envelope = parseSessionJSON(input, { integersOnly: false, maximum: 2097152 });
  const packet = envelope.payload ?? envelope;
  check(packet.type === "session" && plain(packet.data));
  const message = packet.data;
  check(bytes(JSON.stringify(message, (_, value) => value?.[rawNumber] ?? value), 1048576));
  check(message.v === 1 && uuid(message.id) && (message.re === undefined || uuid(message.re)));
  for (const key of ["host_trust_gen", "authorization_ms_left", "server_time", "runtime_epoch", "seq", "ms_left", "lease_epoch", "updated_at"]) {
    if (message[key] !== undefined) check(integer(message[key]));
  }
  if (message.binding !== undefined) check(validBinding(message.binding));
  if (message.detail !== undefined) check(bytes(message.detail, 512));
  switch (message.op) {
    case "hello": case "list": break;
    case "welcome":
      check(opaque(message.account_id) && opaque(message.atem_device_id) && integer(message.host_trust_gen)
        && uuid(message.runtime_gen) && uuid(message.controller_session) && uuid(message.attachment_gen)
        && ["native", "browser"].includes(message.client_kind) && Array.isArray(message.permissions)
        && message.permissions.every((v) => ["view", "control", "approve"].includes(v))
        && integer(message.authorization_ms_left) && integer(message.server_time));
      break;
    case "sessions": case "session_changed":
      check(uuid(message.runtime_gen) && integer(message.runtime_epoch) && integer(message.seq));
      if (message.op === "sessions") {
        check(Array.isArray(message.sessions) && message.sessions.length <= 1024);
        message.sessions.forEach(descriptor);
      } else descriptor(message.descriptor);
      break;
    case "acquire": check(message.binding && message.binding.lease_epoch === undefined && typeof message.takeover === "boolean"); break;
    case "renew": case "release": check(message.binding && integer(message.binding.lease_epoch)); break;
    case "lease": check(uuid(message.re) && message.binding && integer(message.binding.lease_epoch) && integer(message.ms_left) && message.ms_left <= 15000); break;
    case "lease_released": check(uuid(message.re)); break;
    case "lease_changed":
      check(sessionId(message.session_id) && uuid(message.process_gen) && integer(message.lease_epoch) && controller(message.controller)
        && ["granted", "takeover", "local_input", "expired", "released", "revoked", "process_ended"].includes(message.reason));
      break;
    case "submit":
      check(message.binding && integer(message.binding.lease_epoch) && uuid(message.request_id) && ["prompt", "interrupt", "stop"].includes(message.kind));
      check(encoder.encode(canonicalPayload(message.payload)).length <= 65536);
      if (message.kind === "prompt") check(plain(message.payload) && Object.keys(message.payload).length === 1 && bytes(message.payload.text, 32768));
      else check(plain(message.payload) && Object.keys(message.payload).length === 0);
      break;
    case "receipt": receipt(message); break;
    case "receipt_query": check(message.binding && message.binding.lease_epoch === undefined && Array.isArray(message.request_ids)
      && message.request_ids.length <= 64 && message.request_ids.every(uuid)); break;
    case "receipts": check(uuid(message.re) && Array.isArray(message.receipts) && message.receipts.length <= 64); message.receipts.forEach(receipt); break;
    case "error": check(uuid(message.re) && bytes(message.code, 128)); break;
    default: throw new Error("Unsupported session operation");
  }
  return message;
}

export class SessionRegistry {
  constructor() {
    this.sessions = new Map(); this.tombstones = new Map(); this.epoch = null;
    this.runtime = null; this.seq = null; this.needsSnapshot = true; this.requestedList = false;
  }
  apply(message) {
    check(["sessions", "session_changed"].includes(message.op));
    const { runtime_epoch: epoch, runtime_gen: runtime, seq } = message;
    if (this.epoch !== null && epoch < this.epoch) return;
    if (epoch === this.epoch) check(runtime === this.runtime);
    if (epoch !== this.epoch) {
      this.epoch = epoch; this.runtime = runtime; this.seq = null;
      this.sessions.clear(); this.tombstones.clear(); this.needsSnapshot = true;
    }
    if (message.op === "sessions") {
      if (this.seq !== null && seq < this.seq) return;
      check(new Set(message.sessions.map((v) => v.session_id)).size === message.sessions.length);
      const next = new Map();
      for (const value of message.sessions) {
        if (value.state === "removed") this.removed(value);
        else if (!this.tombstones.get(value.session_id)?.has(value.process_gen)) next.set(value.session_id, value);
      }
      this.sessions = next; this.seq = seq; this.needsSnapshot = false;
    } else {
      if (this.needsSnapshot || this.seq === null) { this.requestedList = true; return; }
      if (seq <= this.seq) return;
      if (seq !== this.seq + 1) { this.needsSnapshot = true; this.requestedList = true; return; }
      this.seq = seq;
      const value = message.descriptor;
      if (value.state === "removed") { this.sessions.delete(value.session_id); this.removed(value); }
      else if (!this.tombstones.get(value.session_id)?.has(value.process_gen)) this.sessions.set(value.session_id, value);
    }
    check([...this.tombstones.values()].reduce((count, values) => count + values.size, 0) <= 4096);
  }
  removed(value) {
    const generations = this.tombstones.get(value.session_id) ?? new Set();
    generations.add(value.process_gen);
    this.tombstones.set(value.session_id, generations);
  }
}

export class SessionLease {
  constructor(binding, { now = () => performance.now(), authorizationDeadline = Infinity } = {}) {
    check(validBinding(binding));
    this.binding = binding; this.now = now; this.authorizationDeadline = authorizationDeadline;
    this.deadline = null; this.epoch = null; this.highestEpoch = 0; this.revokedThrough = null; this.pending = new Map();
  }
  get controls() { return this.epoch !== null && this.now() < this.deadline && this.now() < this.authorizationDeadline; }
  sent(message) {
    check(["acquire", "renew"].includes(message.op));
    check(canonicalPayload(message.binding.target) === canonicalPayload(this.binding.target) && message.binding.attachment_gen === this.binding.attachment_gen);
    if (message.op === "renew" && !this.controls) return false;
    if (message.op === "acquire" && !this.controls) { this.pending.clear(); this.epoch = null; }
    this.pending.set(message.id, { sent: this.now(), op: message.op, epoch: message.binding.lease_epoch, previous: this.controls ? this.deadline : null });
    return true;
  }
  receive(message) {
    check(message.op === "lease" && validBinding(message.binding) && integer(message.binding.lease_epoch)
      && integer(message.ms_left) && message.ms_left <= 15000);
    const request = this.pending.get(message.re);
    if (!request) return;
    this.pending.delete(message.re);
    const binding = message.binding;
    if (!binding || binding.attachment_gen !== this.binding.attachment_gen || canonicalPayload(binding.target) !== canonicalPayload(this.binding.target)
      || binding.lease_epoch < this.highestEpoch || (this.revokedThrough !== null && binding.lease_epoch <= this.revokedThrough)
      || (request.op === "renew" && binding.lease_epoch !== request.epoch)) return;
    if (request.previous !== null && this.now() >= request.previous) { this.epoch = null; return; }
    let deadline = Math.min(request.sent + message.ms_left, this.authorizationDeadline);
    if (request.op === "acquire" && request.previous !== null) deadline = Math.min(deadline, request.previous);
    this.deadline = deadline;
    if (this.now() >= deadline) { this.epoch = null; return; }
    this.epoch = binding.lease_epoch; this.highestEpoch = this.epoch;
  }
  revoke(epoch) {
    if (!integer(epoch) || epoch < this.highestEpoch) return;
    this.highestEpoch = epoch; this.revokedThrough = epoch; this.epoch = null; this.pending.clear();
  }
}
