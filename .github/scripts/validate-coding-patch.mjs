import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

import {
  MAX_CODING_FILES,
  MAX_CODING_PATCH_BYTES,
  isProtectedCodingPath,
} from "./coding-policy.mjs";

function git(targetDir, args, options = {}) {
  const result = spawnSync("git", ["-C", targetDir, ...args], {
    encoding: options.encoding || "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(
      `git ${args.join(" ")} failed: ${String(result.stderr || result.stdout).slice(0, 2_000)}`,
    );
  }
  return result.stdout;
}

export function parseNameStatusZ(output) {
  const fields = output.split("\0");
  if (fields.at(-1) === "") fields.pop();
  const changes = [];
  for (let index = 0; index < fields.length; index += 2) {
    const status = fields[index];
    const filename = fields[index + 1];
    if (!status || filename === undefined) {
      throw new Error("Could not parse staged changed-file list.");
    }
    changes.push({ filename, status });
  }
  return changes;
}

function appendOutput(name, value) {
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
  }
}

export function applyAndValidatePatch(patchPath, targetDir) {
  const size = fs.statSync(patchPath).size;
  if (size === 0 || size > MAX_CODING_PATCH_BYTES) {
    throw new Error(
      `Patch size ${size} is outside the allowed range 1-${MAX_CODING_PATCH_BYTES}.`,
    );
  }

  git(targetDir, ["apply", "--check", "--binary", patchPath]);
  git(targetDir, ["apply", "--index", "--binary", patchPath]);
  git(targetDir, ["diff", "--cached", "--check"]);

  const changes = parseNameStatusZ(
    git(targetDir, ["diff", "--cached", "--name-status", "--no-renames", "-z"]),
  );
  if (changes.length === 0 || changes.length > MAX_CODING_FILES) {
    throw new Error(
      `Patch changes ${changes.length} files; the allowed range is 1-${MAX_CODING_FILES}.`,
    );
  }
  const protectedFiles = changes
    .map((change) => change.filename)
    .filter(isProtectedCodingPath);
  if (protectedFiles.length > 0) {
    throw new Error(`Patch modifies protected paths: ${protectedFiles.join(", ")}`);
  }

  const numstat = git(targetDir, [
    "diff",
    "--cached",
    "--numstat",
    "--no-renames",
    "-z",
  ]);
  if (numstat.split("\0").some((entry) => entry.startsWith("-\t-\t"))) {
    throw new Error("Binary changes are not allowed in SMT coding patches.");
  }
  const summary = git(targetDir, ["diff", "--cached", "--summary"]);
  if (/mode (?:120000|160000)/.test(summary)) {
    throw new Error("Symlink and submodule changes are not allowed.");
  }

  const filenames = changes.map((change) => change.filename);
  const stagedEntries = git(
    targetDir,
    ["ls-files", "--stage", "-z", "--", ...filenames],
    { encoding: "buffer" },
  );
  if (Buffer.from(stagedEntries).toString().split("\0").some((entry) => /^(120000|160000) /.test(entry))) {
    throw new Error("Changed files may not be symlinks or submodules.");
  }

  appendOutput("test_relay", filenames.some((name) => name.startsWith("relay-server/")));
  appendOutput("test_webapp", filenames.some((name) => name.startsWith("webapp/")));
  appendOutput("changed_files", filenames.length);
  console.log(`Validated coding patch with ${filenames.length} changed files.`);
  return changes;
}

const isMainModule =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMainModule) {
  try {
    applyAndValidatePatch(process.argv[2], process.argv[3]);
  } catch (error) {
    console.error(error?.stack || error);
    process.exitCode = 1;
  }
}
