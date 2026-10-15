import assert from "node:assert/strict";
import { test } from "node:test";
import { verifyAgentChat } from "../../.github/scripts/verify-station.mjs";

const origin = process.env.WEBAPP_TEST_ORIGIN;

test("webapp serves chat and shared RTC modules without a running relay", { skip: !origin }, async () => {
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
    await verifyAgentChat({ origin, log() {} });

    const redirect = await fetch(new URL("/chat?preview=1", origin), { redirect: "manual" });
    assert.equal(redirect.status, 308);
    assert.equal(new URL(redirect.headers.get("location"), origin).pathname, "/chat/");
    assert.equal(new URL(redirect.headers.get("location"), origin).search, "?preview=1");
    assert.equal(redirect.headers.get("referrer-policy"), "no-referrer");

    for (const path of ["/chat/missing.mjs", "/chat/missing", "/shared/rtc/missing.mjs"]) {
        assert.equal((await fetch(new URL(path, origin))).status, 404, path);
    }
    const rtcPage = await fetch(new URL("/session/test-session", origin));
    assert.equal(rtcPage.status, 200);
    assert.match(await rtcPage.text(), /type="module" src="\/js\/app.mjs"/);
    for (const path of ["/js/app.mjs", "/shared/rtc/channel.mjs", "/shared/rtc/codec.mjs", "/shared/rtc/screen-share.mjs"]) {
        const response = await fetch(new URL(path, origin));
        assert.equal(response.status, 200, path);
        assert.equal(response.headers.get("content-type")?.split(";")[0], "text/javascript", path);
        assert.doesNotMatch(await response.text(), /<!doctype/i);
    }
});
