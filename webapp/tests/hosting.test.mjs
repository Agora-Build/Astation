import assert from "node:assert/strict";
import { test } from "node:test";
import { verifyAgentChat, verifyStoa } from "../../.github/scripts/verify-station.mjs";

const origin = process.env.WEBAPP_TEST_ORIGIN;

test("webapp serves Stoa and Agent and preserves existing links without a running relay", { skip: !origin }, async () => {
    // Allow a freshly started container's entrypoint to render the nginx template.
    let ready = false;
    for (let attempt = 0; attempt < 40; attempt++) {
        try {
            ready = (await fetch(new URL("/", origin))).ok;
            if (ready) break;
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 250));
    }
    assert.ok(ready, "webapp did not become ready");
    await Promise.all([verifyAgentChat({ origin, log() {} }), verifyStoa({ origin, log() {} })]);

    const redirect = await fetch(new URL("/chat?preview=1", origin), { redirect: "manual" });
    assert.equal(redirect.status, 308);
    assert.equal(redirect.headers.get("location"), "/agent/?preview=1");
    assert.equal(new URL(redirect.headers.get("location"), origin).pathname, "/agent/");
    assert.equal(new URL(redirect.headers.get("location"), origin).search, "?preview=1");
    assert.equal(redirect.headers.get("referrer-policy"), "no-referrer");

    for (const [path, target] of [
        ["/agent?preview=1", "/agent/?preview=1"],
        ["/chat/?preview=1", "/agent/?preview=1"],
        ["/chat/chat.mjs?version=1", "/agent/chat.mjs?version=1"],
        ["/session/test-session?view=1", "/stoa/session/test-session?view=1"],
        ["/stoa", "/stoa/"]
    ]) {
        const response = await fetch(new URL(path, origin), { redirect: "manual" });
        assert.equal(response.status, 308, path);
        assert.equal(response.headers.get("location"), target, "redirect must retain the browser's public HTTPS origin");
        const location = new URL(response.headers.get("location"), origin);
        assert.equal(location.pathname + location.search, target);
    }
    for (const path of ["/agent/missing.mjs", "/agent/missing", "/stoa/missing.mjs", "/stoa/rtc/missing.mjs"]) {
        assert.equal((await fetch(new URL(path, origin))).status, 404, path);
    }
    const rtcPage = await fetch(new URL("/stoa/session/test-session", origin));
    assert.equal(rtcPage.status, 200);
    assert.match(await rtcPage.text(), /type="module" src="\/stoa\/app.mjs"/);
    for (const path of ["/stoa/app.mjs", "/stoa/session-link.mjs", "/stoa/rtc/channel.mjs", "/stoa/rtc/codec.mjs", "/stoa/rtc/screen-share.mjs"]) {
        const response = await fetch(new URL(path, origin));
        assert.equal(response.status, 200, path);
        assert.equal(response.headers.get("content-type")?.split(";")[0], "text/javascript", path);
        assert.doesNotMatch(await response.text(), /<!doctype/i);
    }
});
