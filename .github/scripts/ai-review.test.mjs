import assert from "node:assert/strict";
import test from "node:test";

import {
  buildPatchContext,
  extractClaudeReview,
  extractCodexReview,
  modelEndpoint,
  requestModel,
  reviewEligibility,
  validateTestedPullRequest,
} from "./ai-review.mjs";
import {
  isWorkflowChange,
  isWorkflowFile,
  reviewProviderMarker,
  reviewRequestMarker,
  reviewShaMarker,
} from "./review-automation.mjs";

process.env.EXPECTED_CI_JOBS = "Build macOS|Webapp Tests|Relay Server Tests";
process.env.GITHUB_REPOSITORY = "Agora-Build/Astation";

function validationClient({ files, pull, runOverrides = {} }) {
  const sha = "a".repeat(40);
  const run = {
    conclusion: "success",
    event: "pull_request",
    head_sha: sha,
    pull_requests: [{ head: { sha }, number: 12 }],
    workflow_id: 100,
    ...runOverrides,
  };
  return {
    client: {
      root: "/repos/Agora-Build/Astation",
      paginate: async () => files,
      request: async (path) => {
        if (path.endsWith("/actions/runs/123")) return run;
        if (path.endsWith("/actions/workflows/ci.yml")) return { id: 100 };
        if (path.endsWith("/pulls/12")) return pull;
        if (path.includes("/actions/runs/123/jobs")) {
          return {
            jobs: ["Build macOS", "Webapp Tests", "Relay Server Tests"].map(
              (name) => ({ conclusion: "success", name }),
            ),
          };
        }
        throw new Error(`Unexpected test API path: ${path}`);
      },
    },
    run,
    sha,
  };
}

test("builds provider endpoints from configured base URLs", () => {
  assert.equal(
    modelEndpoint("claude", "https://v2.vexke.com/api/"),
    "https://v2.vexke.com/api/v1/messages",
  );
  assert.equal(
    modelEndpoint("codex", "https://v2.vexke.com/openai"),
    "https://v2.vexke.com/openai/v1/responses",
  );
});

test("detects only GitHub workflow files", () => {
  assert.equal(isWorkflowFile(".github/workflows/ci.yml"), true);
  assert.equal(isWorkflowFile(".github/scripts/ai-review.mjs"), false);
  assert.equal(isWorkflowFile("src/workflows/example.yml"), false);
  assert.equal(
    isWorkflowChange({
      filename: "ci.yml.disabled",
      previous_filename: ".github/workflows/ci.yml",
    }),
    true,
  );
});

test("extracts text from Claude and Responses API payloads", () => {
  assert.equal(
    extractClaudeReview({ content: [{ type: "text", text: "No findings." }] }),
    "No findings.",
  );
  assert.equal(
    extractCodexReview({
      output: [{ content: [{ type: "output_text", text: "One finding." }] }],
    }),
    "One finding.",
  );
});

test("keeps the file summary when patch content is truncated", () => {
  const context = buildPatchContext(
    [
      {
        additions: 100,
        deletions: 0,
        filename: "src/example.js",
        patch: "x".repeat(500),
        status: "modified",
      },
    ],
    100,
  );

  assert.match(context, /modified: src\/example\.js \(\+100 -0\)/);
  assert.match(context, /Patch content truncated/);
});

test("caps oversized changed-file summaries", () => {
  const context = buildPatchContext(
    Array.from({ length: 20 }, (_, index) => ({
      additions: 1,
      deletions: 0,
      filename: `src/${index}-${"long-name".repeat(5)}.js`,
      patch: "+const value = true;",
      status: "added",
    })),
    200,
  );

  assert.match(context, /Changed-file summary truncated/);
  assert.ok(context.length < 400);
});

test("validates the exact successful CI jobs and current PR commit", async () => {
  const sha = "a".repeat(40);
  const files = [
    { additions: 1, deletions: 0, filename: "src/example.js", status: "added" },
  ];
  const { client } = validationClient({
    files,
    pull: {
      changed_files: 1,
      head: { repo: { full_name: "Agora-Build/Astation" }, sha },
      number: 12,
      state: "open",
    },
  });

  const context = await validateTestedPullRequest(client, "123");
  assert.equal(context.pull.number, 12);
  assert.deepEqual(context.files, files);
});

test("rejects workflow changes from external pull requests", async () => {
  const files = [
    {
      additions: 1,
      deletions: 0,
      filename: ".github/workflows/ci.yml",
      status: "modified",
    },
  ];
  const sha = "a".repeat(40);
  const { client } = validationClient({
    files,
    pull: {
      changed_files: 1,
      head: { repo: { full_name: "external/fork" }, sha },
      number: 12,
      state: "open",
    },
  });

  await assert.rejects(
    validateTestedPullRequest(client, "123"),
    /External pull requests may not modify workflow files/,
  );
});

test("rejects a partial changed-file listing", async () => {
  const sha = "a".repeat(40);
  const { client } = validationClient({
    files: [],
    pull: {
      changed_files: 1,
      head: { repo: { full_name: "external/fork" }, sha },
      number: 12,
      state: "open",
    },
  });

  await assert.rejects(
    validateTestedPullRequest(client, "123"),
    /refusing a partial policy check and review/,
  );
});

test("validates the tested SHA recorded by an SMT-dispatched CI run", async () => {
  const testedSha = "a".repeat(40);
  const files = [
    { additions: 1, deletions: 0, filename: "src/example.js", status: "added" },
  ];
  const { client } = validationClient({
    files,
    pull: {
      changed_files: 1,
      head: { repo: { full_name: "Agora-Build/Astation" }, sha: testedSha },
      number: 12,
      state: "open",
    },
    runOverrides: {
      event: "workflow_dispatch",
      head_sha: "f".repeat(40),
      pull_requests: [],
    },
  });

  const context = await validateTestedPullRequest(client, "123", {
    headSha: testedSha,
    pullNumber: 12,
  });
  assert.equal(context.run.head_sha, testedSha);
});

test("sends non-agent requests in each provider's native API format", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push({ body: JSON.parse(options.body), headers: options.headers, url });
    const response = url.endsWith("/v1/messages")
      ? { content: [{ text: "Claude review", type: "text" }] }
      : { output: [{ content: [{ text: "Codex review", type: "output_text" }] }] };
    return new Response(JSON.stringify(response), { status: 200 });
  };

  try {
    assert.equal(
      await requestModel("claude", "https://gateway/api", "claude-key", "opus", "diff"),
      "Claude review",
    );
    assert.equal(
      await requestModel("codex", "https://gateway/openai", "codex-key", "gpt", "diff"),
      "Codex review",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }

  assert.equal(requests[0].url, "https://gateway/api/v1/messages");
  assert.equal(requests[0].headers["x-api-key"], "claude-key");
  assert.equal(requests[0].body.messages[0].content, "diff");
  assert.equal(requests[1].url, "https://gateway/openai/v1/responses");
  assert.equal(requests[1].headers.Authorization, "Bearer codex-key");
  assert.equal(requests[1].body.input, "diff");
});

test("reviews internal pull requests immediately after CI", () => {
  const sha = "a".repeat(40);
  const result = reviewEligibility({
    comments: [],
    now: Date.parse("2026-07-21T18:00:00Z"),
    provider: "claude",
    pull: {
      draft: false,
      head: { repo: { full_name: "Agora-Build/Astation" } },
    },
    repository: "Agora-Build/Astation",
    run: { head_sha: sha, updated_at: "2026-07-21T17:59:00Z" },
  });

  assert.equal(result.eligible, true);
});

test("delays external Codex and skips automatic external Claude", () => {
  const sha = "b".repeat(40);
  const input = {
    comments: [],
    now: Date.parse("2026-07-21T18:00:00Z"),
    pull: { draft: false, head: { repo: { full_name: "external/fork" } } },
    repository: "Agora-Build/Astation",
    run: { head_sha: sha, updated_at: "2026-07-21T16:00:01Z" },
    stabilityHours: 3,
  };

  assert.equal(reviewEligibility({ ...input, provider: "codex" }).eligible, false);
  assert.equal(reviewEligibility({ ...input, provider: "claude" }).eligible, false);
  assert.equal(
    reviewEligibility({
      ...input,
      now: Date.parse("2026-07-21T19:00:01Z"),
      provider: "codex",
    }).eligible,
    true,
  );
  assert.equal(
    reviewEligibility({
      ...input,
      now: Date.parse("2026-07-21T19:00:01Z"),
      provider: "claude",
    }).eligible,
    false,
  );
});

test("@smt review overrides external delay and draft status", () => {
  const sha = "c".repeat(40);
  const comments = [
    {
      body: reviewRequestMarker(sha, "manual"),
      user: { login: "github-actions[bot]" },
    },
  ];
  const result = reviewEligibility({
    comments,
    now: Date.parse("2026-07-21T18:00:00Z"),
    provider: "claude",
    pull: { draft: true, head: { repo: { full_name: "external/fork" } } },
    repository: "Agora-Build/Astation",
    run: { head_sha: sha, updated_at: "2026-07-21T17:59:00Z" },
    stabilityHours: 3,
  });

  assert.equal(result.eligible, true);
});

test("deduplicates a provider review for the same commit", () => {
  const sha = "d".repeat(40);
  const comments = [
    {
      body: `${reviewProviderMarker("codex")}\n${reviewShaMarker(sha)}`,
      user: { login: "github-actions[bot]" },
    },
  ];
  const result = reviewEligibility({
    comments,
    provider: "codex",
    pull: {
      draft: false,
      head: { repo: { full_name: "Agora-Build/Astation" } },
    },
    repository: "Agora-Build/Astation",
    run: { head_sha: sha, updated_at: "2026-07-21T17:00:00Z" },
  });

  assert.equal(result.eligible, false);
  assert.match(result.reason, /already reviewed/);
});
