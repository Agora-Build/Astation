import assert from "node:assert/strict";
import { test } from "node:test";
import { joinChannel, publishMicrophone, subscribeTrack } from "../stoa/rtc/channel.mjs";

const identity = { app_id: "app", channel: "channel", token: "matching-token", uid: 1234 };

test("registers subscriptions before join and routes callbacks to the publishing client", async () => {
    const events = [];
    const handlers = {};
    const user = { uid: 5678 };
    const client = {
        on: (event, handler) => { handlers[event] = handler; },
        setClientRole: async role => events.push(["role", role]),
        join: async (...args) => {
            assert.ok(handlers["user-published"]);
            events.push(["join", ...args]);
            handlers["user-published"](user, "video");
        },
        subscribe: async (...args) => events.push(["subscribe", ...args]),
        setRemoteVideoStreamType: async (...args) => events.push(["stream", ...args])
    };
    let callback;
    const joined = await joinChannel({ createClient: () => client }, identity, {
        "user-published": (remote, type, source) => { callback = subscribeTrack(source, remote, type); }
    });
    await callback;
    assert.equal(joined, client);
    assert.deepEqual(events, [
        ["role", "host"], ["join", "app", "channel", "matching-token", 1234],
        ["subscribe", user, "video"], ["stream", 5678, 0]
    ]);
});

test("leaves a partially joined client before codec fallback and cleans up the last failure", async () => {
    const events = [];
    const sdk = { createClient: ({ codec }) => ({
        on() {},
        setClientRole: async () => {},
        join: async () => { events.push(`join:${codec}`); throw new Error("join failed"); },
        leave: async () => { events.push(`leave:${codec}`); }
    }) };
    await assert.rejects(joinChannel(sdk, identity), /join failed/);
    assert.deepEqual(events, ["join:h264", "leave:h264", "join:vp8", "leave:vp8"]);
});

test("a successful microphone publish retains the track; a failure stops then closes it", async () => {
    const events = [];
    const track = { stop: () => events.push("stop"), close: () => events.push("close") };
    const sdk = { createMicrophoneAudioTrack: async () => track };
    assert.equal(await publishMicrophone(sdk, { publish: async tracks => assert.deepEqual(tracks, [track]) }), track);
    assert.deepEqual(events, []);
    await assert.rejects(publishMicrophone(sdk, { publish: async () => { throw new Error("publish failed"); } }), /publish failed/);
    assert.deepEqual(events, ["stop", "close"]);
});

test("audio subscriptions do not request a video stream", async () => {
    const user = { uid: 5678 };
    const events = [];
    await subscribeTrack({ subscribe: async (...args) => events.push(args) }, user, "audio");
    assert.deepEqual(events, [[user, "audio"]]);
});

test("disconnecting while microphone permission is pending closes the late track without publishing", async () => {
    const controller = new AbortController();
    const events = [];
    let resolvePermission;
    const track = { stop: () => events.push("stop"), close: () => events.push("close") };
    const pending = publishMicrophone({
        createMicrophoneAudioTrack: () => new Promise(resolve => { resolvePermission = resolve; })
    }, { publish: async () => events.push("publish") }, { signal: controller.signal });
    controller.abort();
    resolvePermission(track);
    await assert.rejects(pending, { name: "AbortError" });
    assert.deepEqual(events, ["stop", "close"]);
});

test("disconnecting during microphone publication closes the track exactly once", async () => {
    const controller = new AbortController();
    const events = [];
    let resolvePublish;
    const track = { stop: () => events.push("stop"), close: () => events.push("close") };
    const pending = publishMicrophone({ createMicrophoneAudioTrack: async () => track }, {
        publish: () => new Promise(resolve => { resolvePublish = resolve; })
    }, { signal: controller.signal });
    await new Promise(resolve => setImmediate(resolve));
    controller.abort();
    resolvePublish();
    await assert.rejects(pending, { name: "AbortError" });
    assert.deepEqual(events, ["stop", "close"]);
});
