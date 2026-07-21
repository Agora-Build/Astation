import fs from "node:fs";

import {
  canRequestReview,
  createGithubClient,
  dispatchReviewWorkflow,
  hasCompletedReview,
  hasReviewRequest,
  isWorkflowChange,
  latestCiRunForSha,
  listPullRequestComments,
  matchesSmtReviewCommand,
  requireEnv,
  reviewRequestMarker,
} from "./review-automation.mjs";

async function main() {
  const event = JSON.parse(fs.readFileSync(requireEnv("GITHUB_EVENT_PATH"), "utf8"));
  if (!event.issue?.pull_request || !matchesSmtReviewCommand(event.comment?.body)) {
    console.log("Comment is not an @smt review command on a pull request.");
    return;
  }

  const repository = requireEnv("GITHUB_REPOSITORY");
  const client = createGithubClient(requireEnv("GITHUB_TOKEN"), repository);
  const actor = event.comment?.user?.login;
  const permission = await client.request(
    `${client.root}/collaborators/${encodeURIComponent(actor)}/permission`,
  );
  if (!canRequestReview(permission.permission)) {
    console.log(`Ignoring @smt review from ${actor}: write permission is required.`);
    return;
  }

  const pullNumber = event.issue.number;
  const pull = await client.request(`${client.root}/pulls/${pullNumber}`);
  if (pull.state !== "open" || !pull.head?.sha) {
    console.log(`Pull request #${pullNumber} is not open.`);
    return;
  }

  const sha = pull.head.sha;
  if (pull.head?.repo?.full_name !== repository) {
    const files = await client.paginate(
      `${client.root}/pulls/${pullNumber}/files`,
      30,
    );
    if (
      files.length !== pull.changed_files ||
      files.some((file) => isWorkflowChange(file))
    ) {
      throw new Error(
        "External pull requests must not add, modify, delete, or rename workflow files.",
      );
    }
  }

  const comments = await listPullRequestComments(client, pullNumber);
  if (
    hasCompletedReview(comments, "claude", sha) &&
    hasCompletedReview(comments, "codex", sha)
  ) {
    console.log(`Both providers already reviewed commit ${sha}.`);
    return;
  }

  const ciRun = await latestCiRunForSha(client, sha);
  if (!ciRun) {
    throw new Error(`No CI run exists for current pull request commit ${sha}.`);
  }

  let requestComment = null;
  if (!hasReviewRequest(comments, sha, "manual")) {
    let status;
    if (ciRun.status !== "completed") {
      status =
        "The current CI run is still in progress; review will start if it passes.";
    } else if (ciRun.conclusion === "success") {
      status = "CI already passed; Claude and Codex review are starting now.";
    } else {
      status = `The latest CI run concluded with ${ciRun.conclusion}; it is being rerun.`;
    }

    requestComment = await client.request(
      `${client.root}/issues/${pullNumber}/comments`,
      {
        method: "POST",
        body: JSON.stringify({
          body: [
            `AI review requested for commit \`${sha.slice(0, 12)}\`.`,
            status,
            "",
            reviewRequestMarker(sha, "manual"),
          ].join("\n\n"),
        }),
      },
    );
  }

  try {
    if (ciRun.status !== "completed") {
      return;
    }
    if (ciRun.conclusion === "success") {
      const defaultBranch = requireEnv("DEFAULT_BRANCH");
      await dispatchReviewWorkflow(client, "claude", defaultBranch, ciRun.id);
      await dispatchReviewWorkflow(client, "codex", defaultBranch, ciRun.id);
      return;
    }
    await client.request(`${client.root}/actions/runs/${ciRun.id}/rerun`, {
      method: "POST",
    });
  } catch (error) {
    if (requestComment) {
      await client.request(`${client.root}/issues/comments/${requestComment.id}`, {
        method: "DELETE",
      });
    }
    throw error;
  }
}

main().catch((error) => {
  console.error(error?.stack || error);
  process.exitCode = 1;
});
