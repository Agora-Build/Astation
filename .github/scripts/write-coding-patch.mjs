import fs from "node:fs";
import { spawnSync } from "node:child_process";

import { createGithubClient, requireEnv } from "./review-automation.mjs";
import { applyAndValidatePatch } from "./validate-coding-patch.mjs";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed: ${String(result.stderr || result.stdout).slice(0, 2_000)}`,
    );
  }
  return result.stdout.trim();
}

function appendOutput(name, value) {
  fs.appendFileSync(requireEnv("GITHUB_OUTPUT"), `${name}=${value}\n`);
}

async function main() {
  const task = JSON.parse(fs.readFileSync(requireEnv("TASK_PATH"), "utf8"));
  const targetDir = requireEnv("TARGET_DIR");
  const patchPath = requireEnv("PATCH_PATH");
  const client = createGithubClient(
    requireEnv("GITHUB_TOKEN"),
    requireEnv("GITHUB_REPOSITORY"),
  );

  if (run("git", ["rev-parse", "HEAD"], { cwd: targetDir }) !== task.sourceSha) {
    throw new Error("Writer checkout does not match the task's source commit.");
  }
  if (!/^[A-Za-z0-9._/-]+$/.test(task.targetBranch) || task.targetBranch.includes("..")) {
    throw new Error("Task contains an invalid target branch name.");
  }

  if (task.mode === "existing_pr") {
    const pull = await client.request(`${client.root}/pulls/${task.targetPullNumber}`);
    if (
      pull.state !== "open" ||
      pull.head?.repo?.full_name !== task.repository ||
      pull.head?.ref !== task.targetBranch ||
      pull.head?.sha !== task.sourceSha
    ) {
      throw new Error("Target PR changed while the coding task was running; refusing to push.");
    }
  } else {
    const branchExists = spawnSync(
      "git",
      ["ls-remote", "--exit-code", "--heads", "origin", task.targetBranch],
      { cwd: targetDir, encoding: "utf8" },
    );
    if (branchExists.status === 0) {
      throw new Error(`Target branch ${task.targetBranch} already exists.`);
    }
    if (branchExists.status !== 2) {
      throw new Error(`Could not verify target branch: ${branchExists.stderr}`);
    }
  }

  applyAndValidatePatch(patchPath, targetDir);
  run("git", ["config", "user.name", "github-actions[bot]"], { cwd: targetDir });
  run("git", ["config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], {
    cwd: targetDir,
  });
  const subject =
    task.mode === "existing_pr"
      ? `fix: update PR #${task.targetPullNumber}`
      : `fix: address issue #${task.issueNumber}`;
  const message = [
    subject,
    "",
    `Apply the maintainer-requested SMT coding task from comment ${task.commentId}.`,
    "",
    "🤖 Built with SMT <smt@agora.build>",
  ].join("\n");
  run("git", ["commit", "-m", message], { cwd: targetDir });
  const commitSha = run("git", ["rev-parse", "HEAD"], { cwd: targetDir });
  run("git", ["push", "origin", `HEAD:refs/heads/${task.targetBranch}`], {
    cwd: targetDir,
  });

  let pullNumber = task.targetPullNumber;
  let pullUrl;
  if (task.mode === "new_pr") {
    const pull = await client.request(`${client.root}/pulls`, {
      method: "POST",
      body: JSON.stringify({
        base: task.baseBranch,
        body: [
          `Closes #${task.issueNumber}.`,
          "",
          "Created from a maintainer-authorized SMT coding task. CI and AI review run normally on this PR.",
          "",
          "Generated with SMT <smt@agora.build>",
        ].join("\n"),
        head: task.targetBranch,
        title: task.newPullRequestTitle,
      }),
    });
    pullNumber = pull.number;
    pullUrl = pull.html_url;
  } else {
    const pull = await client.request(`${client.root}/pulls/${pullNumber}`);
    pullUrl = pull.html_url;
  }

  await client.request(`${client.root}/actions/workflows/ci.yml/dispatches`, {
    method: "POST",
    body: JSON.stringify({
      inputs: {
        head_sha: commitSha,
        pull_number: String(pullNumber),
      },
      ref: task.baseBranch,
    }),
  });

  appendOutput("commit_sha", commitSha);
  appendOutput("pull_number", pullNumber);
  appendOutput("pull_url", pullUrl);
  console.log(`Pushed ${commitSha} to ${task.targetBranch} for PR #${pullNumber}.`);
}

main().catch((error) => {
  console.error(error?.stack || error);
  process.exitCode = 1;
});
