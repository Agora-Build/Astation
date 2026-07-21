import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  isProtectedCodingPath,
  isProtectedCodingChange,
  parseCodingCommand,
  resolveCodingTarget,
  sanitizePullRequestTitle,
} from "./coding-policy.mjs";
import {
  applyAndValidatePatch,
  parseNameStatusZ,
} from "./validate-coding-patch.mjs";

function git(repo, args) {
  const result = spawnSync("git", ["-C", repo, ...args], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function createPatch(filename) {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "astation-coding-test-"));
  git(repo, ["init", "--quiet"]);
  git(repo, ["config", "user.name", "Test"]);
  git(repo, ["config", "user.email", "test@example.com"]);
  const fullPath = path.join(repo, filename);
  fs.mkdirSync(path.dirname(fullPath), { recursive: true });
  fs.writeFileSync(fullPath, "before\n");
  git(repo, ["add", "."]);
  git(repo, ["commit", "--quiet", "-m", "initial"]);
  fs.writeFileSync(fullPath, "after\n");
  const patchPath = path.join(repo, "change.patch");
  fs.writeFileSync(patchPath, git(repo, ["diff", "--binary", "--full-index", "HEAD"]));
  fs.writeFileSync(fullPath, "before\n");
  return { patchPath, repo };
}

test("parses natural-language fix commands and deterministic PR references", () => {
  assert.deepEqual(parseCodingCommand("@smt fix it"), {
    pullNumbers: [],
    request: "@smt fix it",
  });
  assert.deepEqual(
    parseCodingCommand("@smt please check PR #23, fix this issue, and merge into that PR"),
    {
      pullNumbers: [23],
      request: "@smt please check PR #23, fix this issue, and merge into that PR",
    },
  );
  assert.equal(parseCodingCommand("Please ask @smt to fix it"), null);
  assert.equal(parseCodingCommand("@smt review"), null);
});

test("routes PR comments to that PR and issue comments to a new or explicit PR", () => {
  assert.deepEqual(
    resolveCodingTarget({ currentNumber: 12, isPullRequest: true, pullNumbers: [] }),
    { mode: "existing_pr", pullNumber: 12 },
  );
  assert.deepEqual(
    resolveCodingTarget({ currentNumber: 32, isPullRequest: false, pullNumbers: [] }),
    { mode: "new_pr", pullNumber: null },
  );
  assert.deepEqual(
    resolveCodingTarget({ currentNumber: 32, isPullRequest: false, pullNumbers: [23] }),
    { mode: "existing_pr", pullNumber: 23 },
  );
  assert.throws(
    () =>
      resolveCodingTarget({
        currentNumber: 12,
        isPullRequest: true,
        pullNumbers: [23],
      }),
    /cannot target a different PR/,
  );
});

test("protects automation, instruction, environment, and key paths", () => {
  for (const filename of [
    ".github/workflows/ci.yml",
    ".codex/config.toml",
    ".agents/rules.md",
    "src/AGENTS.md",
    ".env.production",
    "certs/private.pem",
  ]) {
    assert.equal(isProtectedCodingPath(filename), true, filename);
  }
  assert.equal(isProtectedCodingPath("src/app.js"), false);
  assert.equal(
    isProtectedCodingChange({
      filename: "docs/old-instructions.md",
      previous_filename: "AGENTS.md",
    }),
    true,
  );
});

test("sanitizes generated pull request titles", () => {
  assert.equal(sanitizePullRequestTitle("Broken\n  relay", 32), "fix: Broken relay");
  assert.equal(sanitizePullRequestTitle("", 32), "fix: address issue #32");
});

test("recreates the local oss profile from the GitHub Actions base URL", () => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "astation-codex-home-"));
  const result = spawnSync(
    process.execPath,
    [path.join(import.meta.dirname, "prepare-codex-oss-home.mjs")],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        CODEX_HOME: codexHome,
        OPENAI_BASE_URL: "https://gateway.example/openai/",
      },
    },
  );
  assert.equal(result.status, 0, result.stderr);
  const baseConfig = fs.readFileSync(path.join(codexHome, "config.toml"), "utf8");
  const profile = fs.readFileSync(path.join(codexHome, "oss.config.toml"), "utf8");
  assert.match(baseConfig, /base_url = "https:\/\/gateway\.example\/openai"/);
  assert.match(baseConfig, /env_key = "OSS_API_KEY"/);
  assert.match(profile, /model = "gpt-5\.6-sol"/);
  assert.match(profile, /model_reasoning_effort = "xhigh"/);
  assert.match(profile, /web_search = "live"/);
  assert.match(profile, /network_access = false/);
  assert.match(profile, /exclude_tmpdir_env_var = true/);
  assert.match(profile, /exclude_slash_tmp = true/);
  assert.match(profile, /exclude = \["\*KEY\*"/);
  assert.match(profile, /"\*CREDENTIAL\*"/);
});

test("rejects raw and encoded coding credentials in a patch", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "astation-secret-scan-"));
  const patchPath = path.join(dir, "change.patch");
  const secret = "coding-secret-value";
  fs.writeFileSync(patchPath, Buffer.from(secret).toString("base64"));
  const result = spawnSync(
    process.execPath,
    [path.join(import.meta.dirname, "check-coding-patch-secret.mjs")],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATCH_PATH: patchPath,
        SMT_OSS_API_KEY: secret,
      },
    },
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /contains the coding credential/);
});

test("parses NUL-delimited staged changes", () => {
  assert.deepEqual(parseNameStatusZ("M\0src/a.js\0A\0src/b.js\0"), [
    { filename: "src/a.js", status: "M" },
    { filename: "src/b.js", status: "A" },
  ]);
});

test("applies an ordinary text patch", () => {
  const { patchPath, repo } = createPatch("src/example.txt");
  const changes = applyAndValidatePatch(patchPath, repo);
  assert.deepEqual(changes, [{ filename: "src/example.txt", status: "M" }]);
  assert.equal(fs.readFileSync(path.join(repo, "src/example.txt"), "utf8"), "after\n");
});

test("rejects a patch that modifies protected automation paths", () => {
  const { patchPath, repo } = createPatch(".github/workflows/ci.yml");
  assert.throws(
    () => applyAndValidatePatch(patchPath, repo),
    /Patch modifies protected paths/,
  );
});

test("rejects binary patches", () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "astation-binary-test-"));
  git(repo, ["init", "--quiet"]);
  git(repo, ["config", "user.name", "Test"]);
  git(repo, ["config", "user.email", "test@example.com"]);
  const binaryPath = path.join(repo, "asset.bin");
  fs.writeFileSync(binaryPath, Buffer.from([0, 1, 2, 3]));
  git(repo, ["add", "."]);
  git(repo, ["commit", "--quiet", "-m", "initial"]);
  fs.writeFileSync(binaryPath, Buffer.from([0, 1, 9, 3]));
  const patchPath = path.join(repo, "change.patch");
  fs.writeFileSync(patchPath, git(repo, ["diff", "--binary", "--full-index", "HEAD"]));
  fs.writeFileSync(binaryPath, Buffer.from([0, 1, 2, 3]));

  assert.throws(() => applyAndValidatePatch(patchPath, repo), /Binary changes/);
});
