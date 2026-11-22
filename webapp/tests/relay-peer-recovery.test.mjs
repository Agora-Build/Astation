import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { withSharedPeers } from './relay-test-config.mjs';

const image = process.env.WEBAPP_FAILOVER_IMAGE;
const docker = (...args) => execFileSync('docker', args, { encoding: 'utf8', timeout: 120_000 });

test('a recovered relay address is usable immediately after all peers refused connections',
  { skip: !image, timeout: 120_000 }, async t => {
    const directory = mkdtempSync(join(tmpdir(), 'station-peer-recovery-'));
    const network = `station-peer-recovery-${randomUUID()}`;
    const alias = 'relay-recovery-fixture';
    const containers = [];
    t.after(() => {
      for (const name of containers.reverse()) {
        try { docker('rm', '--force', name); } catch {}
      }
      try { docker('network', 'rm', network); } catch {}
      rmSync(directory, { recursive: true, force: true });
    });
    docker('network', 'create', network);
    const backendConfig = join(directory, 'backend.conf');
    writeFileSync(backendConfig, 'server { listen 3000; location / { return 200 "ready"; } }\n');
    const backends = Array.from({ length: 2 }, () => {
      const name = `station-peer-backend-${randomUUID()}`;
      containers.push(name);
      docker('run', '--detach', '--name', name, '--network', network, '--network-alias', alias,
        '--volume', `${backendConfig}:/etc/nginx/conf.d/default.conf:ro`, '--entrypoint', '/bin/sh',
        image, '-ec', 'nginx; exec sleep 3600');
      return name;
    });
    const source = readFileSync(new URL('../nginx.conf', import.meta.url), 'utf8')
      .replaceAll('${STATION_RELAY_UPSTREAM}', `${alias}:3000`);
    const frontends = [];
    for (const [mode, config] of [
      ['production', source],
      ['quarantined-negative-control', withSharedPeers(source,
        `    server ${alias}:3000 resolve max_fails=1;`,
        '    zone recovery_fixture 64k;\n    resolver 127.0.0.11 valid=1s ipv6=off;')],
    ]) {
      const configPath = join(directory, mode + '.conf');
      writeFileSync(configPath, config);
      const name = `station-peer-proxy-${randomUUID()}`;
      containers.push(name);
      docker('run', '--detach', '--name', name, '--network', network,
        '--publish', '127.0.0.1::80', '--volume', `${configPath}:/etc/nginx/conf.d/default.conf:ro`,
        '--entrypoint', 'nginx', image, '-g', 'daemon off;');
      const [{ HostPort: port }] = JSON.parse(docker('inspect', name,
        '--format', '{{json (index .NetworkSettings.Ports "80/tcp")}}'));
      const origin = `http://127.0.0.1:${port}`;
      frontends.push({ origin, name });
      let ready = false;
      for (let attempt = 0; attempt < 80; attempt++) {
        try {
          const response = await fetch(`${origin}/health`, { signal: AbortSignal.timeout(500) });
          await response.arrayBuffer();
          if (response.ok) { ready = true; break; }
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      assert.ok(ready, `isolated ${mode} did not start: ${docker('logs', name)}`);
    }

    // Keep Docker identities/DNS addresses, but close both listeners. This
    // reproduces the shared "no live upstreams" state seen during replacement.
    for (const name of backends) docker('exec', name, 'nginx', '-s', 'stop');
    for (const { origin } of frontends) {
      const response = await fetch(`${origin}/health`, { signal: AbortSignal.timeout(5_000) });
      await response.arrayBuffer();
      assert.equal(response.status, 502);
    }
    docker('exec', backends[0], 'nginx');
    // Complete before the default 10s passive-failure quarantine expires.
    const started = performance.now();
    for (const path of ['/health', '/api/agent/v1/peer-recovery', '/agora-build/peer-recovery']) {
      const response = await fetch(`${frontends[0].origin}${path}`, { signal: AbortSignal.timeout(2_000) });
      assert.equal(response.status, 200, path);
      assert.equal(await response.text(), 'ready');
    }
    const negative = await fetch(`${frontends[1].origin}/health`, { signal: AbortSignal.timeout(2_000) });
    await negative.arrayBuffer();
    assert.equal(negative.status, 502, 'the old quarantine must reproduce the real availability gap');
    assert.ok(performance.now() - started < 8_000, 'recovery must not wait out the passive-failure quarantine');
    const logs = spawnSync('docker', ['logs', frontends[1].name], { encoding: 'utf8', timeout: 10_000 });
    assert.equal(logs.status, 0);
    assert.match(logs.stdout + logs.stderr, /no live upstreams/);
  });
