import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createServer, request } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const image = process.env.WEBAPP_FAILOVER_IMAGE;
const docker = (...args) => execFileSync('docker', args, { encoding: 'utf8', timeout: 120_000 });

function upgrade(origin, path) {
  return new Promise((resolve, reject) => {
    const key = randomBytes(16).toString('base64');
    const url = new URL(origin);
    const [pathname, query] = path.split('?');
    url.pathname = pathname;
    url.search = query || '';
    const call = request(url, { headers: {
      Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': key, Authorization: 'Bearer isolated-failover-test',
    } });
    const timer = setTimeout(() => call.destroy(new Error(`Upgrade timed out: ${path}`)), 8_000);
    call.once('upgrade', (response, socket, head) => {
      clearTimeout(timer);
      try {
        assert.equal(response.statusCode, 101);
        const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        assert.equal(response.headers['sec-websocket-accept'], accept);
        resolve({ socket, head });
      } catch (error) { socket.destroy(); reject(error); }
    });
    call.once('response', response => {
      clearTimeout(timer);
      response.resume();
      reject(new Error(`Upgrade returned HTTP ${response.statusCode}: ${path}`));
    });
    call.once('error', error => { clearTimeout(timer); reject(error); });
    call.end();
  });
}

test('an unresponsive old relay address fails over before the client handshake deadline',
  { skip: !image, timeout: 180_000 }, async t => {
    const directory = mkdtempSync(join(tmpdir(), 'station-relay-failover-'));
    const name = `station-relay-failover-${randomUUID()}`;
    const sockets = new Set();
    const upgrades = [];
    let healthCalls = 0;
    let apiCalls = 0;
    const apiBody = '{"request_id":"isolated-request","text":"fixture only"}';
    const backend = createServer(async (req, res) => {
      if (req.url === '/api/agent/v1/failover-probe') {
        apiCalls++;
        assert.equal(req.method, 'POST');
        assert.equal(req.headers.authorization, 'Bearer isolated-failover-test');
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        assert.equal(Buffer.concat(chunks).toString(), apiBody);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{"stored":true}');
        return;
      }
      assert.equal(req.url, '/health');
      healthCalls++;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"status":"ok"}');
    });
    backend.on('connection', socket => {
      sockets.add(socket);
      socket.once('close', () => sockets.delete(socket));
    });
    backend.on('upgrade', (req, socket) => {
      upgrades.push({ path: req.url, authorization: req.headers.authorization });
      const accept = createHash('sha1').update(req.headers['sec-websocket-key'] +
        '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
        `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      // An established idle stream must outlive the TCP connection deadline.
      const timer = setTimeout(() => socket.write(Buffer.from([0x81, 0x02, 0x6f, 0x6b])), 4_000);
      socket.once('close', () => clearTimeout(timer));
    });
    t.after(async () => {
      try { docker('rm', '--force', name); } catch {}
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => backend.close(resolve));
      rmSync(directory, { recursive: true, force: true });
    });
    backend.listen(0, '0.0.0.0');
    await once(backend, 'listening');
    // Only replace peer discovery to deterministically put a blackholed address
    // first. All production proxy locations and timeouts run unmodified.
    const config = readFileSync(new URL('../nginx.conf', import.meta.url), 'utf8').replace(
      /^upstream station_relay_upstream \{[\s\S]*?^\}/m,
      'upstream station_relay_upstream {\n' +
      '    server 127.0.0.2:9 max_fails=0;\n' +
      `    server host.docker.internal:${backend.address().port} backup;\n}`,
    );
    const configPath = join(directory, 'default.conf');
    writeFileSync(configPath, config);
    docker('run', '--detach', '--name', name, '--cap-add', 'NET_ADMIN',
      '--add-host', 'host.docker.internal:host-gateway', '--publish', '127.0.0.1::80',
      '--volume', `${configPath}:/etc/nginx/conf.d/default.conf:ro`, '--entrypoint', '/bin/sh', image,
      '-ec', 'apk add --no-cache iptables; ' +
      'iptables -A OUTPUT -p tcp -d 127.0.0.2 --dport 9 -j DROP; ' +
      'exec nginx -g "daemon off;"');
    const [{ HostPort: port }] = JSON.parse(docker('inspect', name,
      '--format', '{{json (index .NetworkSettings.Ports "80/tcp")}}'));
    const origin = `http://127.0.0.1:${port}`;
    let ready = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      try {
        ready = (await fetch(origin, { signal: AbortSignal.timeout(500) })).ok;
        if (ready) break;
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    if (!ready) {
      const logs = docker('logs', name);
      assert.fail(`isolated nginx did not start: ${logs}`);
    }
    const started = performance.now();
    const health = await fetch(new URL('/health', origin), { signal: AbortSignal.timeout(8_000) });
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { status: 'ok' });
    assert.equal(healthCalls, 1);
    assert.ok(performance.now() - started >= 2_500, 'the request must actually encounter the blackholed peer');
    // Connecting to an obsolete peer must not consume the API client's deadline
    // or turn one POST into more than one backend acceptance.
    const result = await fetch(new URL('/api/agent/v1/failover-probe', origin), {
      method: 'POST', headers: { Authorization: 'Bearer isolated-failover-test', 'Content-Type': 'application/json' },
      body: apiBody, signal: AbortSignal.timeout(8_000),
    });
    assert.equal(result.status, 200);
    assert.deepEqual(await result.json(), { stored: true });
    assert.equal(apiCalls, 1);
    for (const path of ['/ws?proof=isolated', '//ws?proof=isolated', '/ws/proxy?proof=isolated']) {
      const { socket, head } = await upgrade(origin, path);
      try {
        socket.setTimeout(6_000, () => socket.destroy(new Error('upgraded stream timed out')));
        const chunks = [head];
        let length = head.length;
        while (length < 4) {
          const [chunk] = await once(socket, 'data');
          chunks.push(chunk); length += chunk.length;
        }
        assert.deepEqual(Buffer.concat(chunks), Buffer.from([0x81, 0x02, 0x6f, 0x6b]));
      } finally { socket.destroy(); }
    }
    assert.deepEqual(upgrades, [
      { path: '/ws?proof=isolated', authorization: 'Bearer isolated-failover-test' },
      { path: '/ws?proof=isolated', authorization: 'Bearer isolated-failover-test' },
      { path: '/ws/proxy?proof=isolated', authorization: 'Bearer isolated-failover-test' },
    ]);
  });
