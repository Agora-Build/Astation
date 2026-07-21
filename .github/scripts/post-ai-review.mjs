import fs from "node:fs";

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function trimTrailingSlash(value) {
  return value.replace(/\/+$/, "");
}

function truncateUtf8(value, maxBytes) {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) {
    return value;
  }
  let end = Math.min(value.length, maxBytes);
  while (end > 0 && Buffer.byteLength(value.slice(0, end), "utf8") > maxBytes) {
    end -= 1;
  }
  return `${value.slice(0, end)}\n\n[Review truncated to fit GitHub's comment limit.]`;
}

async function main() {
  const token = requireEnv("GITHUB_TOKEN");
  const repository = requireEnv("GITHUB_REPOSITORY");
  const apiUrl = trimTrailingSlash(process.env.GITHUB_API_URL || "https://api.github.com");
  const root = `/repos/${repository}`;
  const output = JSON.parse(fs.readFileSync(requireEnv("REVIEW_OUTPUT_PATH"), "utf8"));

  if (!Number.isInteger(output.pullRequest) || !/^[0-9a-f]{40}$/.test(output.headSha)) {
    throw new Error("Review artifact contains invalid pull request metadata.");
  }
  if (!["claude", "codex"].includes(output.provider) || !output.review?.trim()) {
    throw new Error("Review artifact contains invalid review output.");
  }

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
    if (!response.ok) {
      const detail = (await response.text()).slice(0, 1_000);
      throw new Error(`GitHub API ${response.status} for ${path}: ${detail}`);
    }
    return response.status === 204 ? null : response.json();
  }

  const pull = await request(`${root}/pulls/${output.pullRequest}`);
  if (pull.state !== "open" || pull.head?.sha !== output.headSha) {
    console.log(`Skipping stale review for pull request #${output.pullRequest}.`);
    return;
  }

  const displayName = output.provider === "claude" ? "Claude" : "Codex";
  const marker = `<!-- astation-ai-review:${output.provider} -->`;
  const suffix = `\n\n${marker}`;
  const body = `${truncateUtf8(
    `## ${displayName} Code Review\n\n${output.review.trim()}`,
    60_000 - Buffer.byteLength(suffix, "utf8"),
  )}${suffix}`;

  const comments = [];
  for (let page = 1; ; page += 1) {
    const batch = await request(
      `${root}/issues/${output.pullRequest}/comments?per_page=100&page=${page}`,
    );
    comments.push(...batch);
    if (batch.length < 100) {
      break;
    }
  }
  const existing = comments.find(
    (comment) =>
      comment.user?.login === "github-actions[bot]" && comment.body?.includes(marker),
  );
  if (existing) {
    await request(`${root}/issues/comments/${existing.id}`, {
      method: "PATCH",
      body: JSON.stringify({ body }),
    });
    console.log(`Updated ${displayName} review on pull request #${output.pullRequest}.`);
  } else {
    await request(`${root}/issues/${output.pullRequest}/comments`, {
      method: "POST",
      body: JSON.stringify({ body }),
    });
    console.log(`Posted ${displayName} review on pull request #${output.pullRequest}.`);
  }
}

main().catch((error) => {
  console.error(error?.stack || error);
  process.exitCode = 1;
});
