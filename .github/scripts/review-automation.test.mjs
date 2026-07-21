import assert from "node:assert/strict";
import test from "node:test";

import {
  canRequestReview,
  dispatchReviewWorkflow,
  hasCompletedReview,
  hasReviewRequest,
  isStableSince,
  latestCiRunForSha,
  matchesSmtReviewCommand,
  reviewProviderMarker,
  reviewRequestMarker,
  reviewShaMarker,
} from "./review-automation.mjs";

test("accepts only an exact @smt command line", () => {
  assert.equal(matchesSmtReviewCommand("@smt"), true);
  assert.equal(matchesSmtReviewCommand("Please run this\n@smt review"), true);
  assert.equal(matchesSmtReviewCommand("Can someone ask @smt review this?"), false);
  assert.equal(matchesSmtReviewCommand("> @smt review"), false);
});

test("allows only repository writers to spend review credits", () => {
  assert.equal(canRequestReview("admin"), true);
  assert.equal(canRequestReview("maintain"), true);
  assert.equal(canRequestReview("write"), true);
  assert.equal(canRequestReview("triage"), false);
  assert.equal(canRequestReview("read"), false);
});

test("requires bot-authored provider and SHA markers for deduplication", () => {
  const sha = "a".repeat(40);
  const body = `${reviewProviderMarker("codex")}\n${reviewShaMarker(sha)}`;
  assert.equal(
    hasCompletedReview([{ body, user: { login: "github-actions[bot]" } }], "codex", sha),
    true,
  );
  assert.equal(
    hasCompletedReview([{ body, user: { login: "external-user" } }], "codex", sha),
    false,
  );
  assert.equal(
    hasCompletedReview(
      [{ body: reviewProviderMarker("codex"), user: { login: "github-actions[bot]" } }],
      "codex",
      sha,
    ),
    false,
  );
});

test("distinguishes manual and scheduled requests for the current SHA", () => {
  const sha = "b".repeat(40);
  const comments = [
    {
      body: reviewRequestMarker(sha, "scheduled"),
      user: { login: "github-actions[bot]" },
    },
  ];
  assert.equal(hasReviewRequest(comments, sha), true);
  assert.equal(hasReviewRequest(comments, sha, "scheduled"), true);
  assert.equal(hasReviewRequest(comments, sha, "manual"), false);
  assert.equal(hasReviewRequest(comments, "c".repeat(40)), false);
});

test("measures stability from the successful CI completion time", () => {
  const now = Date.parse("2026-07-21T18:00:00Z");
  assert.equal(isStableSince("2026-07-21T15:00:00Z", 3, now), true);
  assert.equal(isStableSince("2026-07-21T15:00:01Z", 3, now), false);
  assert.equal(isStableSince("invalid", 3, now), false);
});

test("looks up CI by the exact head SHA", async () => {
  const sha = "d".repeat(40);
  let requestedPath;
  const run = { head_sha: sha, id: 123 };
  const client = {
    root: "/repos/Agora-Build/Astation",
    request: async (path) => {
      requestedPath = path;
      return { workflow_runs: [run] };
    },
  };

  assert.deepEqual(await latestCiRunForSha(client, sha), run);
  assert.match(requestedPath, new RegExp(`head_sha=${sha}`));
});

test("dispatches the selected provider with a tested CI run ID", async () => {
  let request;
  const client = {
    root: "/repos/Agora-Build/Astation",
    request: async (path, options) => {
      request = { options, path };
    },
  };

  await dispatchReviewWorkflow(client, "codex", "main", 123);
  assert.equal(
    request.path,
    "/repos/Agora-Build/Astation/actions/workflows/codex-code-review.yml/dispatches",
  );
  assert.deepEqual(JSON.parse(request.options.body), {
    inputs: { ci_run_id: "123" },
    ref: "main",
  });
});
