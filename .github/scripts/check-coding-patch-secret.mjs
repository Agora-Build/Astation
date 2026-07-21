import fs from "node:fs";

import { requireEnv } from "./review-automation.mjs";

const secret = requireEnv("SMT_OSS_API_KEY");
const patch = fs.readFileSync(requireEnv("PATCH_PATH"));
const encodings = [
  Buffer.from(secret),
  Buffer.from(secret).toString("base64"),
  Buffer.from(secret).toString("hex"),
];

if (encodings.some((value) => patch.includes(value))) {
  throw new Error("Generated patch contains the coding credential or an encoding of it.");
}
