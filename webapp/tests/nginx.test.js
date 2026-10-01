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

for (const path of ["ws", "health"]) {
  const location = config.match(
    new RegExp(`location\\s*=\\s*\\/${path}\\s*\\{([\\s\\S]*?)\\}`),
  );
  assert.ok(location, `nginx must proxy the exact /${path} path`);
  assert.match(
    location[1],
    /proxy_next_upstream\s+error\s+timeout\s+http_502\s+http_503;/,
    `/${path} must move on to another relay replica when one refuses, fails or drains`,
  );
}

assert.match(
  config,
  /resolver\s+127\.0\.0\.11\s+valid=10s/,
  "nginx must re-resolve the relay alias every 10 s",
);
assert.match(
  config,
  /server\s+\$\{STATION_RELAY_UPSTREAM\}\s+resolve;/,
  "nginx must balance across every address of the relay alias",
);

console.log("nginx proxy tests passed");
