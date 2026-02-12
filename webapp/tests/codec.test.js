const assert = require("assert");
const { preferredCodec, fallbackCodec, pickCodec } = require("../js/codec.js");

assert.strictEqual(preferredCodec, "av1");
assert.strictEqual(fallbackCodec, "vp8");

assert.strictEqual(pickCodec("av1", ["h264", "vp8"]), "vp8");
assert.strictEqual(pickCodec("av1", ["av1", "vp8"]), "av1");
assert.strictEqual(pickCodec("av1", []), "vp8");
assert.strictEqual(pickCodec("av1", null), "vp8");

console.log("codec.test.js: ok");
