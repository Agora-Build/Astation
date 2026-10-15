import assert from "node:assert/strict";
import { test } from "node:test";
import { sessionIdFromInput, sessionIdFromPath, sessionPath } from "../stoa/session-link.mjs";

test("Stoa accepts canonical and existing Astation session links", () => {
    for (const value of [
        "session-123", "  session-123  ", "/stoa/session/session-123", "/session/session-123/",
        "https://station.agora.build/stoa/session/session-123?from=share#view",
        "https://station.agora.build/session/session-123",
        "https://stoa.agora.build/session/session-123"
    ]) {
        const id = sessionIdFromInput(value);
        assert.equal(id, "session-123");
        assert.equal(sessionPath(id), "/stoa/session/session-123");
    }
});

test("Stoa resolves session IDs from complete routes rather than partial paths", () => {
    assert.equal(sessionIdFromPath("/stoa/session/AbC-123"), "AbC-123");
    for (const path of ["/stoa/", "/session/", "/stoa/session/abc/extra", "/stoa/session/a%2Fb", "/agent/"]) {
        assert.equal(sessionIdFromPath(path), null, path);
    }
});

test("Stoa rejects unsafe URLs and invalid session IDs", () => {
    for (const value of [
        "javascript:alert(1)", "file:///session/abc", "https://user:pass@example.test/session/abc",
        "https://example.test/?session=abc", "../abc", "", "a".repeat(129)
    ]) {
        assert.equal(sessionIdFromInput(value), null, value);
    }
    assert.throws(() => sessionPath("../agent/"), /Invalid session ID/);
});
