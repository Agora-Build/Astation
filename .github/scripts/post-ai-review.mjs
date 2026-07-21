import fs from "node:fs";

import {
  ACTIONS_BOT_LOGIN,
  createGithubClient,
  listPullRequestComments,
  requireEnv,
  reviewProviderMarker,
  reviewShaMarker,
} from "./review-automation.mjs";

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
  const client = createGithubClient(token, repository);
  const output = JSON.parse(fs.readFileSync(requireEnv("REVIEW_OUTPUT_PATH"), "utf8"));

  if (!Number.isInteger(output.pullRequest) || !/^[0-9a-f]{40}$/.test(output.headSha)) {
    throw new Error("Review artifact contains invalid pull request metadata.");
  }
  if (!["claude", "codex"].includes(output.provider) || !output.review?.trim()) {
    throw new Error("Review artifact contains invalid review output.");
  }

  const pull = await client.request(`${client.root}/pulls/${output.pullRequest}`);
  if (pull.state !== "open" || pull.head?.sha !== output.headSha) {
    console.log(`Skipping stale review for pull request #${output.pullRequest}.`);
    return;
  }

  const displayName = output.provider === "claude" ? "Claude" : "Codex";
  const marker = reviewProviderMarker(output.provider);
  const suffix = `\n\n${marker}\n${reviewShaMarker(output.headSha)}`;
  const body = `${truncateUtf8(
    `## ${displayName} Code Review\n\n${output.review.trim()}`,
    60_000 - Buffer.byteLength(suffix, "utf8"),
  )}${suffix}`;

  const comments = await listPullRequestComments(client, output.pullRequest);
  const existing = comments.find(
    (comment) =>
      comment.user?.login === ACTIONS_BOT_LOGIN && comment.body?.includes(marker),
  );
  if (existing) {
    await client.request(`${client.root}/issues/comments/${existing.id}`, {
      method: "PATCH",
      body: JSON.stringify({ body }),
    });
    console.log(`Updated ${displayName} review on pull request #${output.pullRequest}.`);
  } else {
    await client.request(`${client.root}/issues/${output.pullRequest}/comments`, {
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
