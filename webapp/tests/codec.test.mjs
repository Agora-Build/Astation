import assert from "node:assert/strict";
import { preferredCodec, fallbackCodec, pickCodec } from "../stoa/rtc/codec.mjs";

assert.strictEqual(preferredCodec, "h264");
assert.strictEqual(fallbackCodec, "vp8");

assert.strictEqual(pickCodec("av1", ["h264", "vp8"]), "vp8");
assert.strictEqual(pickCodec("av1", ["av1", "vp8"]), "av1");
assert.strictEqual(pickCodec("av1", []), "vp8");
assert.strictEqual(pickCodec("av1", null), "vp8");

console.log("codec.test.mjs: ok");
