import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { withSharedPeers } from '../../webapp/tests/relay-test-config.mjs';

const image = process.env.WEBAPP_FAILOVER_IMAGE;
const docker = (...args) => execFileSync('docker', args, { encoding: 'utf8', timeout: 120_000 });
const routes = [
  '/api/agent/v1/replay-probe', '/api/skills/batch', '/api/memory/batch',
  '/api/replay-probe', '/agora-build/replay-probe', '/auth/replay-probe', '/pair/replay-probe',
];

test('accepted POSTs are not replayed when a relay loses its reply or returns busy',
  { skip: !image, timeout: 120_000 }, async t => {
    const directory = mkdtempSync(join(tmpdir(), 'station-post-replay-'));
    const containers = new Set(), sockets = new Set(), received = new Map();
    const backends = Array.from({ length: 2 }, () => createServer(async (req, res) => {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const bytes = Buffer.concat(chunks).toString();
      const body = JSON.parse(bytes);
      const calls = received.get(body.request_id) || [];
      calls.push({ method: req.method, path: req.url, authorization: req.headers.authorization, bytes });
      received.set(body.request_id, calls);
      // Count acceptance only after the complete body arrives, then lose the reply.
      if (body.reply === 'lost') req.socket.destroy();
      else {
        res.writeHead(body.reply === 'busy' ? 503 : 200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ accepted: true }));
      }
    }));
    t.after(async () => {
      for (const name of containers) {
        try { docker('rm', '--force', name); } catch {}
      }
      for (const socket of sockets) socket.destroy();
      await Promise.all(backends.map(backend => new Promise(resolve => backend.close(resolve))));
      rmSync(directory, { recursive: true, force: true });
    });
    for (const backend of backends) {
      backend.on('connection', socket => {
        sockets.add(socket);
        socket.once('close', () => sockets.delete(socket));
      });
      backend.listen(0, '0.0.0.0');
      await once(backend, 'listening');
    }
    const source = readFileSync(new URL('../../webapp/nginx.conf', import.meta.url), 'utf8');
    const peers = backends.map(backend =>
      `    server host.docker.internal:${backend.address().port} max_fails=0;`).join('\n');
    const production = withSharedPeers(source, peers);

    async function start(config, mode) {
      const configPath = join(directory, mode + '.conf');
      writeFileSync(configPath, config);
      const name = `station-post-replay-${randomUUID()}`;
      containers.add(name);
      docker('run', '--detach', '--name', name,
        '--add-host', 'host.docker.internal:host-gateway', '--publish', '127.0.0.1::80',
        '--volume', `${configPath}:/etc/nginx/conf.d/default.conf:ro`, '--entrypoint', 'nginx',
        image, '-g', 'daemon off;');
      const [{ HostPort: port }] = JSON.parse(docker('inspect', name,
        '--format', '{{json (index .NetworkSettings.Ports "80/tcp")}}'));
      const origin = `http://127.0.0.1:${port}`;
      for (let attempt = 0; attempt < 80; attempt++) {
        try {
          const response = await fetch(origin, { signal: AbortSignal.timeout(500) });
          await response.arrayBuffer();
          if (response.ok) return { origin, name };
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      assert.fail(`isolated nginx did not start: ${docker('logs', name)}`);
    }

    async function probe(origin, route, reply, acceptances) {
      const requestID = randomUUID();
      const bytes = JSON.stringify({ request_id: requestID, reply });
      const response = await fetch(new URL(route, origin), {
        method: 'POST', signal: AbortSignal.timeout(8_000),
        headers: { Authorization: 'Bearer isolated-post-replay-test', 'Content-Type': 'application/json' },
        body: bytes,
      });
      await response.arrayBuffer();
      assert.equal(response.status, reply === 'lost' ? 502 : reply === 'busy' ? 503 : 200);
      const calls = received.get(requestID) || [];
      assert.equal(calls.length, acceptances, 'one request must have the expected backend acceptance count');
      for (const call of calls) assert.deepEqual(call, {
        method: 'POST', path: route, authorization: 'Bearer isolated-post-replay-test', bytes,
      });
    }

    const current = await start(production, 'production');
    for (const route of routes) {
      for (const reply of ['ok', 'lost', 'busy']) {
        await t.test(`${route}: ${reply}`, () => probe(current.origin, route, reply, 1));
      }
    }
    docker('rm', '--force', current.name);
    containers.delete(current.name);

    // Prove the fixture detects replay, rather than passing with one usable peer.
    const unsafe = production.replace('    listen 80;',
      '    listen 80;\n    proxy_next_upstream error timeout non_idempotent;');
    assert.notEqual(unsafe, production, 'the negative control must enable unsafe POST retries');
    const negative = await start(unsafe, 'unsafe-negative-control');
    await t.test('unsafe retry permission causes two backend acceptances',
      () => probe(negative.origin, routes[0], 'lost', 2));
  });
