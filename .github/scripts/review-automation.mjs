export const ACTIONS_BOT_LOGIN = "github-actions[bot]";
export const DEFAULT_STABILITY_HOURS = 3;

export function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function trimTrailingSlash(value) {
  return value.replace(/\/+$/, "");
}

export function createGithubClient(token, repository) {
  const apiUrl = trimTrailingSlash(
    process.env.GITHUB_API_URL || "https://api.github.com",
  );
  const root = `/repos/${repository}`;

  async function request(path, options = {}) {
    const response = await fetch(`${apiUrl}${path}`, {
      ...options,
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
        ...options.headers,
      },
      signal: AbortSignal.timeout(60_000),
    });
    const responseText = await response.text();
    if (!response.ok) {
      throw new Error(
        `GitHub API ${response.status} for ${path}: ${responseText.slice(0, 1_000)}`,
      );
    }
    return responseText ? JSON.parse(responseText) : null;
  }

  async function paginate(path, maxPages = Number.POSITIVE_INFINITY) {
    const separator = path.includes("?") ? "&" : "?";
    const items = [];
    for (let page = 1; page <= maxPages; page += 1) {
      const batch = await request(`${path}${separator}per_page=100&page=${page}`);
      if (!Array.isArray(batch)) {
        throw new Error(`Expected an array from GitHub API path: ${path}`);
      }
      items.push(...batch);
      if (batch.length < 100) {
        break;
      }
    }
    return items;
  }

  return { paginate, request, root };
}

export function isWorkflowFile(filename) {
  return filename.startsWith(".github/workflows/");
}

export function isWorkflowChange(file) {
  return (
    isWorkflowFile(file.filename) ||
    (typeof file.previous_filename === "string" &&
      isWorkflowFile(file.previous_filename))
  );
}

export function reviewProviderMarker(provider) {
  return `<!-- astation-ai-review:${provider} -->`;
}

export function reviewShaMarker(sha) {
  return `<!-- astation-ai-review-sha:${sha} -->`;
}

export function reviewRequestMarker(sha, mode) {
  return `<!-- astation-ai-review-request:${sha}:${mode} -->`;
}

function isActionsBotComment(comment) {
  return comment.user?.login === ACTIONS_BOT_LOGIN && typeof comment.body === "string";
}

export function hasCompletedReview(comments, provider, sha) {
  const providerMarker = reviewProviderMarker(provider);
  const shaMarker = reviewShaMarker(sha);
  return comments.some(
    (comment) =>
      isActionsBotComment(comment) &&
      comment.body.includes(providerMarker) &&
      comment.body.includes(shaMarker),
  );
}

export function hasReviewRequest(comments, sha, mode) {
  const exactMarker = mode ? reviewRequestMarker(sha, mode) : null;
  const markerPrefix = `<!-- astation-ai-review-request:${sha}:`;
  return comments.some(
    (comment) =>
      isActionsBotComment(comment) &&
      (exactMarker
        ? comment.body.includes(exactMarker)
        : comment.body.includes(markerPrefix)),
  );
}

export function matchesSmtReviewCommand(body) {
  return String(body || "")
    .split(/\r?\n/)
    .some((line) => ["@smt", "@smt review"].includes(line.trim().toLowerCase()));
}

export function canRequestReview(permission) {
  return ["admin", "maintain", "write"].includes(permission);
}

export function isStableSince(timestamp, hours, now = Date.now()) {
  const since = Date.parse(timestamp);
  const duration = Number(hours) * 60 * 60 * 1_000;
  return Number.isFinite(since) && Number.isFinite(duration) && now - since >= duration;
}

export async function listPullRequestComments(client, pullNumber) {
  return client.paginate(`${client.root}/issues/${pullNumber}/comments`);
}

export async function latestCiRunForSha(client, sha) {
  const query = new URLSearchParams({
    event: "pull_request",
    head_sha: sha,
    per_page: "100",
  });
  const response = await client.request(
    `${client.root}/actions/workflows/ci.yml/runs?${query}`,
  );
  return (response.workflow_runs || []).find((run) => run.head_sha === sha) || null;
}

export async function dispatchReviewWorkflow(
  client,
  provider,
  defaultBranch,
  ciRunId,
) {
  const workflow =
    provider === "claude" ? "claude-code-review.yml" : "codex-code-review.yml";
  await client.request(`${client.root}/actions/workflows/${workflow}/dispatches`, {
    method: "POST",
    body: JSON.stringify({
      inputs: { ci_run_id: String(ciRunId) },
      ref: defaultBranch,
    }),
  });
}
