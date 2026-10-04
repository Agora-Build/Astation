const assert = require("node:assert/strict");
const { test } = require("node:test");
const { ScreenPublisher } = require("../js/screen-share.js");

function rig({ audio = false, picker, joinError = false } = {}) {
    const events = [];
    const handler = {};
    const video = {
        getMediaStreamTrack: () => ({ getSettings: () => ({ width: 3840, height: 2160 }) }),
        setEncoderConfiguration: async config => events.push(["encoder", config]),
        on: (event, callback) => { handler[event] = callback; },
        stop: () => events.push("video-stop"), close: () => events.push("video-close")
    };
    const audioTrack = { stop: () => events.push("audio-stop"), close: () => events.push("audio-close") };
    const sdk = {
        createScreenVideoTrack: async (config, withAudio) => {
            events.push(["picker", withAudio]);
            if (picker) await picker;
            return audio ? [video, audioTrack] : video;
        },
        createClient: config => {
            events.push(["client", config]);
            return {
                setClientRole: async role => events.push(["role", role]),
                join: async (...args) => { events.push(["join", ...args]); if (joinError) throw new Error("join failed"); },
                publish: async tracks => events.push(["publish", tracks.length]),
                leave: async () => events.push("leave")
            };
        }
    };
    let allocations = 0;
    const publisher = new ScreenPublisher(sdk, async () => {
        allocations++;
        return { app_id: "app", channel: "room", token: "matching-token", uid: 1234 };
    }, (state, noAudio) => events.push(["state", state, noAudio]));
    return { publisher, events, handler, allocations: () => allocations };
}

test("publishes native dimensions with optional system audio on a separate identity", async () => {
    const r = rig({ audio: true });
    await r.publisher.start(true);
    assert.deepEqual(r.events.find(e => e[0] === "picker"), ["picker", "auto"]);
    assert.deepEqual(r.events.find(e => e[0] === "encoder")[1], { width: 3840, height: 2160, frameRate: 60 });
    assert.deepEqual(r.events.find(e => e[0] === "join"), ["join", "app", "room", "matching-token", 1234]);
    assert.deepEqual(r.events.find(e => e[0] === "publish"), ["publish", 2]);
    assert.deepEqual(r.events.find(e => e[0] === "role"), ["role", "host"]);
    await r.publisher.stop();
    assert.equal(r.events.filter(e => e === "video-close").length, 1);
    assert.equal(r.events.filter(e => e === "audio-close").length, 1);
    await r.publisher.start(false);
    assert.equal(r.allocations(), 1); // Restarting sharing must not consume another participant slot.
    await r.publisher.stop();
});

test("reports unavailable browser audio and handles the browser Stop button", async () => {
    const r = rig();
    await r.publisher.start(true);
    assert.ok(r.events.some(e => e[0] === "state" && e[1] === "sharing" && e[2] === true));
    r.handler["track-ended"]();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(r.publisher.active, false);
    assert.equal(r.events.filter(e => e === "video-close").length, 1);
});

test("cancelling while the picker is open closes the returned track without joining", async () => {
    let resolvePicker;
    const picker = new Promise(resolve => { resolvePicker = resolve; });
    const r = rig({ picker });
    const starting = r.publisher.start(false);
    await r.publisher.stop();
    resolvePicker();
    await starting;
    assert.equal(r.allocations(), 0);
    assert.equal(r.events.filter(e => e === "video-close").length, 1);
    assert.equal(r.publisher.active, false);
});

test("failed joins close both tracks and leave the partial client", async () => {
    const r = rig({ audio: true, joinError: true });
    await assert.rejects(r.publisher.start(true), /join failed/);
    assert.equal(r.events.filter(e => e === "video-close").length, 1);
    assert.equal(r.events.filter(e => e === "audio-close").length, 1);
    assert.equal(r.events.filter(e => e === "leave").length, 1);
    assert.equal(r.publisher.active, false);
});
