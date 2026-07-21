import fs from "node:fs";

import { createGithubClient, requireEnv } from "./review-automation.mjs";

const client = createGithubClient(
  requireEnv("GITHUB_TOKEN"),
  requireEnv("GITHUB_REPOSITORY"),
);
const run = await client.request(
  `${client.root}/actions/runs/${requireEnv("WORKFLOW_RUN_ID")}`,
);
fs.appendFileSync(requireEnv("GITHUB_OUTPUT"), `event=${run.event}\n`);
