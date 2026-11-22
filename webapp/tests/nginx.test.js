const assert = require("assert");
const fs = require("fs");
const path = require("path");

const config = fs.readFileSync(path.join(__dirname, "..", "nginx.conf"), "utf8");
const healthLocation = config.match(/location\s*=\s*\/health\s*\{([\s\S]*?)\}/);

assert.ok(healthLocation, "nginx must proxy the exact /health path");
assert.match(
  healthLocation[1],
  /proxy_pass\s+http:\/\/\$station_relay;/,
  "/health must use the relay upstream",
);
assert.match(
  healthLocation[1],
  /proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;/,
  "/health must preserve the public request scheme",
);

for (const path of ["ws", "ws/proxy", "health"]) {
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

const nativeProxyLocation = config.match(/location\s*=\s*\/ws\/proxy\s*\{([\s\S]*?)\}/);
assert.match(nativeProxyLocation[1], /proxy_pass\s+http:\/\/\$station_relay\/ws\/proxy\$is_args\$args;/);
assert.match(nativeProxyLocation[1], /proxy_http_version\s+1\.1;/);
assert.match(nativeProxyLocation[1], /proxy_set_header\s+Upgrade\s+\$http_upgrade;/);
assert.doesNotMatch(nativeProxyLocation[1], /proxy_set_header\s+Authorization\s+""|try_files/);

assert.match(
  config,
  /resolver\s+127\.0\.0\.11\s+valid=1s/,
  "nginx must promptly refresh replaced relay addresses",
);
assert.match(
  config,
  /set\s+\$station_relay\s+\$\{STATION_RELAY_UPSTREAM\};/,
  "nginx must resolve the relay alias for each request's own peer list",
);
assert.doesNotMatch(config, /upstream\s+station_relay_upstream|\szone\s/,
  "a live DNS refresh must not invalidate a shared peer generation during retry");
assert.match(config, /resolver_timeout\s+1s;/,
  "DNS lookup must fit inside the client connection budget");
const wsLocation = config.match(/location\s*=\s*\/ws\s*\{([\s\S]*?)\}/);
assert.match(wsLocation[1], /proxy_pass\s+http:\/\/\$station_relay\/ws\$is_args\$args;/,
  "normalized WebSocket paths must retain their query parameters");

console.log("nginx proxy tests passed");

// /metrics is scraped from each relay container directly; it must never be
// reachable through nginx (it would leak operational info).
const metricsLocation = config.match(/location\s*=\s*\/metrics\s*\{([\s\S]*?)\}/);
assert.ok(metricsLocation, "nginx must answer /metrics explicitly");
assert.match(metricsLocation[1], /return\s+404\s*;/, "/metrics must be 404 at nginx");
assert.ok(
  !/proxy_pass[^;]*metrics/.test(config),
  "nginx must not proxy /metrics to the relay",
);

const chatLocation = config.match(/location\s+\/agent\/\s*\{([\s\S]*?)\}/);
assert.ok(chatLocation, "nginx must serve Agent from the webapp image");
assert.match(chatLocation[1], /try_files\s+\$uri\s+\$uri\/\s+=404;/);
assert.doesNotMatch(chatLocation[1], /proxy_pass|\/index\.html/);
assert.match(chatLocation[1], /add_header\s+Content-Security-Policy\s+"default-src 'none';/);
assert.match(config, /types\s*\{\s*text\/javascript\s+mjs;/);
assert.match(config, /location\s*=\s*\/agent\s*\{[^}]*return\s+308\s+\/agent\/\$is_args\$args;/);
assert.match(config, /location\s+\/stoa\/session\/\s*\{\s*try_files\s+\/stoa\/index\.html\s+=404;/);
