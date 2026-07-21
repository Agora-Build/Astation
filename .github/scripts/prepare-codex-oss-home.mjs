import fs from "node:fs";
import path from "node:path";

import { requireEnv } from "./review-automation.mjs";

const codexHome = requireEnv("CODEX_HOME");
const baseUrl = requireEnv("OPENAI_BASE_URL").replace(/\/+$/, "");
fs.mkdirSync(codexHome, { recursive: true, mode: 0o700 });

fs.writeFileSync(
  path.join(codexHome, "config.toml"),
  [
    "[model_providers.oss]",
    'name = "SMT OSS"',
    `base_url = ${JSON.stringify(baseUrl)}`,
    'env_key = "OSS_API_KEY"',
    'wire_api = "responses"',
    "requires_openai_auth = true",
    "",
  ].join("\n"),
  { mode: 0o600 },
);

fs.writeFileSync(
  path.join(codexHome, "oss.config.toml"),
  [
    'model_provider = "oss"',
    'model = "gpt-5.6-sol"',
    'model_reasoning_effort = "xhigh"',
    'approval_policy = "never"',
    'sandbox_mode = "workspace-write"',
    "allow_login_shell = false",
    'web_search = "disabled"',
    "",
    "[sandbox_workspace_write]",
    "network_access = false",
    "exclude_tmpdir_env_var = true",
    "exclude_slash_tmp = true",
    "writable_roots = []",
    "",
    "[shell_environment_policy]",
    'inherit = "core"',
    "ignore_default_excludes = false",
    'exclude = ["*KEY*", "*TOKEN*", "*SECRET*", "GITHUB_*", "ACTIONS_*"]',
    "",
  ].join("\n"),
  { mode: 0o600 },
);
