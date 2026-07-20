const assert = require("assert");
const fs = require("fs");
const path = require("path");

const config = fs.readFileSync(path.join(__dirname, "..", "nginx.conf"), "utf8");
const healthLocation = config.match(/location\s*=\s*\/health\s*\{([\s\S]*?)\}/);

assert.ok(healthLocation, "nginx must proxy the exact /health path");
assert.match(
  healthLocation[1],
  /proxy_pass\s+http:\/\/station_relay_upstream;/,
  "/health must use the relay upstream",
);
assert.match(
  healthLocation[1],
  /proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;/,
  "/health must preserve the public request scheme",
);

console.log("nginx health proxy test passed");
