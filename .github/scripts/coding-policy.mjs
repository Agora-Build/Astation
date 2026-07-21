import { ACTIONS_BOT_LOGIN } from "./review-automation.mjs";

export const MAX_CODING_FILES = 30;
export const MAX_CODING_PATCH_BYTES = 512_000;

export function codingTaskMarker(commentId) {
  return `<!-- astation-coding-task:${commentId} -->`;
}

export function hasCodingTask(comments, commentId) {
  const marker = codingTaskMarker(commentId);
  return comments.some(
    (comment) =>
      comment.user?.login === ACTIONS_BOT_LOGIN && comment.body?.includes(marker),
  );
}

export function parseCodingCommand(body) {
  const lines = String(body || "").split(/\r?\n/);
  const commandIndex = lines.findIndex((line) => /^\s*@smt\b/i.test(line));
  if (commandIndex < 0) {
    return null;
  }

  const request = lines.slice(commandIndex).join("\n").trim();
  if (!/\bfix\b/i.test(request)) {
    return null;
  }

  const pullNumbers = new Set();
  for (const match of request.matchAll(/\b(?:pr|pull\s+request)\s*#(\d+)\b/gi)) {
    pullNumbers.add(Number(match[1]));
  }
  return { pullNumbers: [...pullNumbers], request };
}

export function resolveCodingTarget({ currentNumber, isPullRequest, pullNumbers }) {
  if (pullNumbers.length > 1) {
    throw new Error("Coding commands may reference at most one pull request.");
  }
  const explicitPull = pullNumbers[0] || null;
  if (isPullRequest && explicitPull && explicitPull !== currentNumber) {
    throw new Error(
      `Command on PR #${currentNumber} cannot target a different PR #${explicitPull}.`,
    );
  }
  if (isPullRequest) {
    return { mode: "existing_pr", pullNumber: currentNumber };
  }
  if (explicitPull) {
    return { mode: "existing_pr", pullNumber: explicitPull };
  }
  return { mode: "new_pr", pullNumber: null };
}

export function isProtectedCodingPath(filename) {
  const parts = filename.split("/");
  const basename = parts.at(-1) || "";
  return (
    filename === ".github" ||
    filename.startsWith(".github/") ||
    filename === ".agents" ||
    filename.startsWith(".agents/") ||
    filename === ".codex" ||
    filename.startsWith(".codex/") ||
    filename === ".gitmodules" ||
    parts.includes("AGENTS.md") ||
    basename === ".env" ||
    basename.startsWith(".env.") ||
    /\.(?:key|pem|p12|pfx)$/i.test(basename)
  );
}

export function isProtectedCodingChange(file) {
  return (
    isProtectedCodingPath(file.filename) ||
    (typeof file.previous_filename === "string" &&
      isProtectedCodingPath(file.previous_filename))
  );
}

export function sanitizePullRequestTitle(title, issueNumber) {
  const clean = String(title || "")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 72);
  return clean ? `fix: ${clean}` : `fix: address issue #${issueNumber}`;
}
