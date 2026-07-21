import {
  DEFAULT_STABILITY_HOURS,
  createGithubClient,
  dispatchReviewWorkflow,
  hasCompletedReview,
  hasReviewRequest,
  isStableSince,
  isWorkflowChange,
  latestCiRunForSha,
  listPullRequestComments,
  requireEnv,
  reviewRequestMarker,
} from "./review-automation.mjs";

const MAX_OPEN_PR_PAGES = 10;
const MAX_CHANGED_FILE_PAGES = 30;

async function main() {
  const repository = requireEnv("GITHUB_REPOSITORY");
  const defaultBranch = requireEnv("DEFAULT_BRANCH");
  const stabilityHours = Number(
    process.env.EXTERNAL_REVIEW_STABILITY_HOURS || DEFAULT_STABILITY_HOURS,
  );
  const client = createGithubClient(requireEnv("GITHUB_TOKEN"), repository);
  const pulls = await client.paginate(
    `${client.root}/pulls?state=open&sort=updated&direction=desc`,
    MAX_OPEN_PR_PAGES,
  );

  for (const pullSummary of pulls) {
    if (
      pullSummary.draft ||
      !pullSummary.head?.sha ||
      pullSummary.head?.repo?.full_name === repository
    ) {
      continue;
    }

    const pullNumber = pullSummary.number;
    const sha = pullSummary.head.sha;
    const comments = await listPullRequestComments(client, pullNumber);
    if (
      hasCompletedReview(comments, "codex", sha) ||
      hasReviewRequest(comments, sha)
    ) {
      continue;
    }

    const ciRun = await latestCiRunForSha(client, sha);
    if (
      !ciRun ||
      ciRun.status !== "completed" ||
      ciRun.conclusion !== "success" ||
      !isStableSince(ciRun.updated_at, stabilityHours)
    ) {
      continue;
    }

    const pull = await client.request(`${client.root}/pulls/${pullNumber}`);
    if (pull.state !== "open" || pull.head?.sha !== sha) {
      continue;
    }
    const files = await client.paginate(
      `${client.root}/pulls/${pullNumber}/files`,
      MAX_CHANGED_FILE_PAGES,
    );
    if (
      files.length !== pull.changed_files ||
      files.some((file) => isWorkflowChange(file))
    ) {
      console.log(`Skipping external pull request #${pullNumber}: workflow policy.`);
      continue;
    }

    const requestComment = await client.request(
      `${client.root}/issues/${pullNumber}/comments`,
      {
        method: "POST",
        body: JSON.stringify({
          body: [
            `Codex review queued for stable commit \`${sha.slice(0, 12)}\`.`,
            "",
            reviewRequestMarker(sha, "scheduled"),
          ].join("\n"),
        }),
      },
    );

    try {
      await dispatchReviewWorkflow(client, "codex", defaultBranch, ciRun.id);
      console.log(`Queued Codex review for external pull request #${pullNumber}.`);
    } catch (error) {
      await client.request(`${client.root}/issues/comments/${requestComment.id}`, {
        method: "DELETE",
      });
      throw error;
    }
  }
}

main().catch((error) => {
  console.error(error?.stack || error);
  process.exitCode = 1;
});
