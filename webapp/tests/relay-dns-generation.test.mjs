import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { createServer, request } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { withSharedPeers } from './relay-test-config.mjs';

const image = process.env.WEBAPP_FAILOVER_IMAGE;
const docker = (...args) => execFileSync('docker', args, { encoding: 'utf8', timeout: 120_000 });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function call(origin, path, body) {
  return new Promise((resolve, reject) => {
    const websocket = path.startsWith('/ws');
    const headers = websocket ? { Connection: 'Upgrade', Upgrade: 'websocket',
      'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': Buffer.alloc(16, 1).toString('base64') } : {};
    const req = request(new URL(path, origin), { method: body ? 'POST' : 'GET', headers, agent: false });
    const timer = setTimeout(() => req.destroy(new Error('DNS-change request timed out')), 8_000);
    req.once('upgrade', (res, socket) => { clearTimeout(timer); socket.destroy(); resolve(res.statusCode); });
    req.once('response', res => {
      res.resume();
      res.once('end', () => { clearTimeout(timer); resolve(res.statusCode); });
    });
    req.once('error', error => { clearTimeout(timer); reject(error); });
    req.end(body);
  });
}

test('DNS replacement during a stalled connection preserves every request remaining peer',
  { skip: !image, timeout: 180_000 }, async t => {
    const directory = mkdtempSync(join(tmpdir(), 'station-dns-generation-'));
    const containers = [], sockets = new Set(), accepted = new Map();
    const dns = createSocket('udp4');
    let replaced = false, initialQueries = 0, replacementQueries = 0;
    const gateway = docker('network', 'inspect', 'bridge', '--format', '{{(index .IPAM.Config 0).Gateway}}').trim();
    assert.match(gateway, /^(\d{1,3}\.){3}\d{1,3}$/);
    const backend = createServer(async (req, res) => {
      if (req.method === 'POST') {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const id = Buffer.concat(chunks).toString();
        accepted.set(id, (accepted.get(id) || 0) + 1);
      }
      res.end('ready');
    });
    backend.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    backend.on('upgrade', (req, socket) => {
      const accept = createHash('sha1').update(req.headers['sec-websocket-key'] +
        '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.end('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
        `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    });
    t.after(async () => {
      for (const name of containers.reverse()) { try { docker('rm', '--force', name); } catch {} }
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => backend.close(resolve));
      dns.close();
      rmSync(directory, { recursive: true, force: true });
    });
    backend.listen(0, '0.0.0.0');
    await once(backend, 'listening');
    // The old address silently drops TCP. While those attempts wait, DNS stops
    // advertising it. The healthy address is present before and after the change.
    dns.on('message', (packet, sender) => {
      let end = 12;
      while (packet[end]) end += packet[end] + 1;
      end += 5;
      // Keep two slots across replacement so the old shared group's generation
      // check (rather than its single-peer shortcut) must handle the retry.
      const addresses = replaced ? ['127.0.0.3', gateway] : ['127.0.0.2', gateway];
      if (replaced) replacementQueries++; else initialQueries++;
      const header = Buffer.from([packet[0], packet[1], 0x81, 0x80, 0, 1, 0, addresses.length, 0, 0, 0, 0]);
      const answers = addresses.map(ip => Buffer.from([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 0, 0, 4,
        ...ip.split('.').map(Number)]));
      dns.send(Buffer.concat([header, packet.subarray(12, end), ...answers]), sender.port, sender.address);
    });
    dns.bind(0, '0.0.0.0');
    await once(dns, 'listening');
    const resolver = `resolver host.docker.internal:${dns.address().port} valid=1s ipv6=off;`;
    const source = readFileSync(new URL('../nginx.conf', import.meta.url), 'utf8')
      .replace('resolver 127.0.0.11 valid=1s ipv6=off;', resolver)
      .replaceAll('${STATION_RELAY_UPSTREAM}', `relay-fixture.test:${backend.address().port}`);
    const origins = [];
    for (const [mode, config] of [
      ['production', source],
      ['shared-generation-negative-control', withSharedPeers(source,
        `    server relay-fixture.test:${backend.address().port} resolve max_fails=0;`,
        `    zone generation_fixture 64k;\n    ${resolver}`)],
    ]) {
      const configPath = join(directory, mode + '.conf');
      writeFileSync(configPath, config);
      const name = `station-dns-generation-${randomUUID()}`;
      containers.push(name);
      docker('run', '--detach', '--name', name, '--cap-add', 'NET_ADMIN',
        '--add-host', 'host.docker.internal:host-gateway', '--publish', '127.0.0.1::80',
        '--volume', `${configPath}:/etc/nginx/conf.d/default.conf:ro`, '--entrypoint', '/bin/sh', image,
        '-ec', 'apk add --no-cache iptables; ' +
        `iptables -A OUTPUT -p tcp -d 127.0.0.2 --dport ${backend.address().port} -j DROP; ` +
        'exec nginx -g "daemon off;"');
      const [{ HostPort: port }] = JSON.parse(docker('inspect', name,
        '--format', '{{json (index .NetworkSettings.Ports "80/tcp")}}'));
      const origin = `http://127.0.0.1:${port}`;
      let ready = false;
      for (let attempt = 0; attempt < 100; attempt++) {
        try {
          const response = await fetch(origin, { signal: AbortSignal.timeout(500) });
          await response.arrayBuffer();
          if (response.ok) { ready = true; break; }
        } catch {}
        await sleep(100);
      }
      assert.ok(ready, `${mode} failed to start`);
      origins.push(origin);
    }
    assert.ok(initialQueries > 0, 'the shared negative control must have its initial two-address generation');
    const ids = [], productionIDs = [];
    function burst(origin, recordIDs) {
      return Promise.all(Array.from({ length: 6 }, (_, i) => {
        const id = randomUUID(); ids.push(id); recordIDs?.push(id);
        return Promise.all([call(origin, '/health'), call(origin, `/ws?probe=${i}`),
          call(origin, '/api/agent/v1/dns-change-probe', id)]);
      })).then(rows => rows.flat());
    }
    const started = performance.now();
    const production = burst(origins[0], productionIDs), negative = burst(origins[1]);
    await sleep(400);
    replaced = true;
    const [good, bad] = await Promise.all([production, negative]);
    assert.ok(replacementQueries > 0, 'DNS must change while the old connection is waiting');
    assert.ok(performance.now() - started >= 2_500, 'the fixture must encounter the blackholed address');
    assert.deepEqual(good, Array.from({ length: 6 }, () => [200, 101, 200]).flat());
    assert.ok(bad.some(status => status === 502 || status === 504),
      `the shared-generation negative control must fail: ${bad}`);
    for (const id of productionIDs) assert.equal(accepted.get(id), 1, 'each production POST must reach one peer');
    for (const id of ids) assert.ok((accepted.get(id) || 0) <= 1, 'no accepted POST may be replayed');
    for (const origin of origins) assert.equal(await call(origin, '/health'), 200, 'the new generation is healthy');
    const logs = spawnSync('docker', ['logs', containers[1]], { encoding: 'utf8', timeout: 10_000 });
    assert.equal(logs.status, 0);
    assert.match(logs.stdout + logs.stderr, /no live upstreams/);
  });
