import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";
import test from "node:test";
import {
  BROWSER_SESSION_ACCESS_ENABLED, canonicalPayload, payloadDigest, parseSessionJSON,
  decodeSessionPacket, SessionRegistry, SessionLease,
} from "../agent/session-protocol.mjs";

const root = new URL("../../Tests/AstationTests/Fixtures/atem-session-v1/", import.meta.url);
const fixture = async (name) => JSON.parse(await readFile(new URL(`${name}.json`, root), "utf8"));
const decode = (packet) => decodeSessionPacket(JSON.stringify(packet));

test("r5 shared digest vectors and rejection vectors use the wire parser", async () => {
  const vectors = await fixture("digest-vectors");
  for (const vector of vectors.vectors) {
    const payload = parseSessionJSON(JSON.stringify(vector.payload));
    assert.equal(canonicalPayload(payload), vector.canonical, vector.name);
    assert.equal(await payloadDigest(payload, webcrypto), vector.sha256, vector.name);
  }
  for (const vector of vectors.must_reject) {
    const input = vector.payload_json ?? Buffer.from(vector.payload_hex, "hex");
    assert.throws(() => parseSessionJSON(input), vector.name);
  }
});

test("shared fixture copies match the pinned protocol snapshot", async () => {
  const source = await fixture("source");
  assert.equal(source.commit, "44987915fb24267960fd9d75221df4ed8c7838ec");
  for (const name of ["digest-vectors", "late-renew-reply-does-not-resurrect-control", "runtime-epoch-and-sequence-ordering",
    "lease-expires-without-renewal", "duplicate-submit-returns-receipt-and-reuse-is-rejected", "legacy-connection-cannot-bypass-lease",
    "dispatch-failure-before-any-effect-is-rejected", "dispatch-failure-after-partial-write-is-outcome-unknown"]) {
    assert.equal(await readFile(new URL(`${name}.json`, root), "utf8"),
      await readFile(new URL(`../../designs/protocol/fixtures/${name}.json`, import.meta.url), "utf8"));
  }
});

test("Unicode key identity stays exact and escaped duplicate keys are rejected", () => {
  assert.equal(canonicalPayload(parseSessionJSON('{"\\u00e9":1,"e\\u0301":2}')), '{"e\u0301":2,"\u00e9":1}');
  assert.throws(() => parseSessionJSON('{"a":1,"\\u0061":2}'));
  assert.throws(() => parseSessionJSON('{"__proto__":1,"__proto__":2}'));
});

test("duplicate relay payloads and unsafe counter spellings are rejected", () => {
  const id = "11111111-1111-4111-8111-000000000001";
  for (const raw of [
    `{"type":"session","data":{"v":1,"v":1,"op":"list","id":"${id}"}}`,
    `{"type":"session","data":{"v":1e0,"op":"list","id":"${id}"}}`,
    `{"type":"session","data":{"v":1,"op":"list","id":"${id}","seq":9007199254740992}}`,
    `{"payload":{"type":"session","data":{"v":1,"op":"list","id":"${id}"}},"payload":{}}`,
  ]) assert.throws(() => decodeSessionPacket(raw));
  assert.equal(decodeSessionPacket(`{"type":"session","data":{"v":1,"op":"list","id":"${id}","future":{"fraction":1.5}}}`).op, "list");
});

test("shared client lease fixture includes expiry equality and no late reply resurrection", async () => {
  const scenario = await fixture("late-renew-reply-does-not-resurrect-control");
  let now = 0;
  const binding = scenario.steps.find((step) => step.send).json.data.binding;
  const lease = new SessionLease(binding, { now: () => now });
  for (const step of scenario.steps) {
    if (step.advance_ms !== undefined) now += step.advance_ms;
    if (step.send) assert.equal(lease.sent(decode(step.json)), true);
    if (step.deliver_to_client) lease.receive(decode(step.json));
    const expected = step.assert_client;
    if (expected) {
      if (expected.controls !== undefined) assert.equal(lease.controls, expected.controls);
      if (expected.input_enabled !== undefined) assert.equal(lease.controls, expected.input_enabled);
      if (expected.deadline_ms !== undefined) assert.equal(lease.deadline, expected.deadline_ms);
    }
  }
});

test("shared registry fixture uses complete wire messages and rejects resurrection", async () => {
  const scenario = await fixture("runtime-epoch-and-sequence-ordering");
  const registry = new SessionRegistry();
  for (const step of scenario.steps) {
    if (step.deliver_to_client) registry.apply(decode(step.json));
    const expected = step.assert_client;
    if (expected) {
      if (expected.registry) assert.deepEqual([...registry.sessions.keys()].sort(), [...expected.registry].sort());
      if (expected.runtime_epoch !== undefined) assert.equal(registry.epoch, expected.runtime_epoch);
      if (expected.seq !== undefined) assert.equal(registry.seq, expected.seq);
      if (expected.sent_list) assert.equal(registry.requestedList, true);
      if (expected.registry_state) {
        for (const [id, state] of Object.entries(expected.registry_state)) assert.equal(registry.sessions.get(id)?.state, state);
      }
    }
  }
});

test("descriptors require explicit controller and complete removal values", async () => {
  const scenario = await fixture("runtime-epoch-and-sequence-ordering");
  const packet = scenario.steps[0].json;
  for (const key of Object.keys(packet.data.sessions[0])) {
    const invalid = structuredClone(packet);
    delete invalid.data.sessions[0][key];
    assert.throws(() => decode(invalid), key);
  }
});

test("removing a second process cannot forget an earlier tombstone", async () => {
  const scenario = await fixture("runtime-epoch-and-sequence-ordering");
  const snapshot = decode(scenario.steps[0].json);
  const registry = new SessionRegistry();
  registry.apply(snapshot);
  const first = snapshot.sessions[0];
  const second = "77777777-7777-4777-8777-777777777777";
  for (const [offset, state, process_gen] of [[1, "removed", first.process_gen], [2, "running", second], [3, "removed", second], [4, "running", first.process_gen]]) {
    registry.apply({ ...snapshot, op: "session_changed", seq: snapshot.seq + offset, descriptor: { ...first, state, process_gen } });
  }
  assert.equal(registry.sessions.has(first.session_id), false);
});

test("local takeover fences renew replies, and expiry cannot renew itself", async () => {
  const scenario = await fixture("late-renew-reply-does-not-resurrect-control");
  const acquire = scenario.steps[0].json.data;
  const reply = scenario.steps[1].json.data;
  let now = 0;
  const lease = new SessionLease(acquire.binding, { now: () => now });
  lease.sent(acquire); lease.receive(reply);
  now = 5000;
  const renew = scenario.steps[4].json.data;
  lease.sent(renew); lease.revoke(2);
  lease.receive({ ...reply, re: renew.id });
  assert.equal(lease.controls, false);
  now = 15000;
  assert.equal(lease.sent(renew), false);
  assert.equal(lease.controls, false);
  lease.sent({ ...acquire, id: "new-acquire" });
  lease.receive({ ...reply, re: "new-acquire", binding: { ...reply.binding, lease_epoch: 2 } });
  assert.equal(lease.controls, false, "The revoked epoch cannot be granted again");
  lease.sent({ ...acquire, id: "explicit-acquire" });
  lease.receive({ ...reply, re: "explicit-acquire", binding: { ...reply.binding, lease_epoch: 3 } });
  assert.equal(lease.controls, true);
});

test("browser host access stays disabled until section 9 is implemented", () => {
  assert.equal(BROWSER_SESSION_ACCESS_ENABLED, false);
});
