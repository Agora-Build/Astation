import assert from 'node:assert/strict';
import test from 'node:test';
import { healthProblems, settingsFromEnv, waitForHealth, verifyAgentChat } from './verify-station.mjs';

const healthy = { status: 'ok', knowledge_store: 'postgres', redis: 'ok', replicas: 2 };

test('a healthy cluster has no problems', () => {
  assert.deepEqual(healthProblems(healthy, { minReplicas: 2, requireRedis: true }), []);
});

test('redis and the replica count are checked', () => {
  assert.deepEqual(healthProblems({ ...healthy, redis: 'disabled', replicas: 1 }, { minReplicas: 2, requireRedis: true }), [
    'relay redis is disabled, expected ok',
    'relay reports 1 live replica(s), expected at least 2',
  ]);
  assert.deepEqual(healthProblems({ ...healthy, redis: 'disabled', replicas: 1 }, { minReplicas: 1, requireRedis: false }), []);
  assert.deepEqual(healthProblems({ ...healthy, knowledge_store: 'memory' }, { minReplicas: 1, requireRedis: true }), [
    'relay knowledge store is memory, expected postgres',
  ]);
  assert.deepEqual(healthProblems({ status: 'draining' }, { minReplicas: 1, requireRedis: false }), [
    'relay status is draining',
    'relay knowledge store is undefined, expected postgres',
    'relay reports 0 live replica(s), expected at least 1',
  ]);
  // Legacy health responses remain accepted when Redis and replica checks are disabled.
  assert.deepEqual(healthProblems({ status: 'ok', knowledge_store: 'postgres' }), []);
  assert.deepEqual(healthProblems({ ...healthy, redis: 'unavailable' }, { requireRedis: true }), [
    'relay redis is unavailable, expected ok',
  ]);
});

test('settings come from the environment', () => {
  assert.deepEqual(settingsFromEnv({}), {
    origin: 'https://station.agora.build',
    minReplicas: 0,
    requireRedis: false,
    expectedCommit: null,
  });
  assert.deepEqual(
    settingsFromEnv({ STATION_URL: 'https://x.test', STATION_MIN_REPLICAS: '2', STATION_REQUIRE_REDIS: '1' }),
    { origin: 'https://x.test', minReplicas: 2, requireRedis: true, expectedCommit: null },
  );
  assert.throws(() => settingsFromEnv({ STATION_MIN_REPLICAS: 'two' }), /STATION_MIN_REPLICAS/);
});

test('build verification is optional and rejects a stale or missing commit', () => {
  const expectedCommit = 'a'.repeat(40);
  assert.deepEqual(healthProblems(healthy), []);
  assert.deepEqual(healthProblems(healthy, { expectedCommit }), [
    `relay build commit is missing, expected ${expectedCommit}`,
  ]);
  assert.deepEqual(healthProblems({ ...healthy, build_commit: 'b'.repeat(40) }, { expectedCommit }), [
    `relay build commit is ${'b'.repeat(40)}, expected ${expectedCommit}`,
  ]);
  assert.deepEqual(healthProblems({ ...healthy, build_commit: expectedCommit }, { expectedCommit }), []);
});

test('expected build settings require a full commit and accept uppercase input', () => {
  assert.equal(settingsFromEnv({ STATION_EXPECTED_COMMIT: ` ${'A'.repeat(40)} ` }).expectedCommit, 'a'.repeat(40));
  assert.equal(settingsFromEnv({ STATION_EXPECTED_COMMIT: ' ' }).expectedCommit, null);
  for (const value of ['main', 'unknown', 'abcdef0', 'g'.repeat(40)]) {
    assert.throws(() => settingsFromEnv({ STATION_EXPECTED_COMMIT: value }), /STATION_EXPECTED_COMMIT/);
  }
});

test('health waits for the requested build after a rollout', async () => {
  const expectedCommit = 'a'.repeat(40);
  const responses = [
    { ...healthy, build_commit: 'b'.repeat(40) },
    { ...healthy, build_commit: expectedCommit },
  ];
  const logs = [];
  const health = await waitForHealth({
    origin: 'https://station.test', minReplicas: 2, requireRedis: true, expectedCommit,
    fetchImpl: async () => new Response(JSON.stringify(responses.shift())),
    sleep: async () => {}, log: message => logs.push(message), attempts: 2,
  });
  assert.equal(health.build_commit, expectedCommit);
  assert.match(logs[0], /Waiting.*build commit/);
});

test('waitForHealth polls until the cluster is healthy', async () => {
  const responses = [
    new Response('{}', { status: 502 }),
    new Response(JSON.stringify({ ...healthy, replicas: 1 })),
    new Response(JSON.stringify(healthy)),
  ];
  const logs = [];
  const health = await waitForHealth({
    origin: 'https://station.test',
    minReplicas: 2,
    requireRedis: true,
    fetchImpl: async () => responses.shift(),
    sleep: async () => {},
    log: line => logs.push(line),
    attempts: 5,
  });
  assert.equal(health.replicas, 2);
  assert.equal(logs.length, 3);
});

test('waitForHealth gives up', async () => {
  await assert.rejects(
    waitForHealth({
      origin: 'https://station.test',
      minReplicas: 1,
      requireRedis: true,
      fetchImpl: async () => new Response('{}', { status: 503 }),
      sleep: async () => {},
      log: () => {},
      attempts: 2,
    }),
    /did not become healthy: \/health returned HTTP 503/,
  );
});

function chatAsset(path) {
  const values = {
    '/chat/': ['text/html', '<!doctype html><form id="composer"></form>'],
    '/chat/chat.css': ['text/css', ':root { --paper: white; }'],
    '/chat/chat-core.mjs': ['text/javascript', 'export class Conversation {}'],
    '/chat/chat.mjs': ['text/javascript', 'import "./chat-core.mjs";'],
    '/chat/mark.svg': ['image/svg+xml', '<svg></svg>'],
  };
  const [mime, text] = values[path];
  return new Response(text, { headers: {
    'content-type': `${mime}; charset=utf-8`,
    'cache-control': 'no-store', 'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
    'content-security-policy': "default-src 'none'; script-src 'self'; frame-ancestors 'none'",
  } });
}

test('production verification checks the relay app and every asset on the same origin', async () => {
  const paths = [];
  await verifyAgentChat({ origin: 'https://station.test', log: () => {}, fetchImpl: async (url, options) => {
    assert.equal(url.origin, 'https://station.test');
    assert.equal(options.redirect, 'error');
    paths.push(url.pathname);
    return chatAsset(url.pathname);
  } });
  assert.deepEqual(paths.sort(), ['/chat/', '/chat/chat.css', '/chat/chat-core.mjs', '/chat/chat.mjs', '/chat/mark.svg'].sort());
});

test('production verification rejects an undeployed page, SPA fallback and wrong JavaScript MIME', async () => {
  for (const broken of [
    () => new Response('Not found', { status: 404 }),
    () => new Response('<!doctype html><html>RTC</html>', { headers: { 'content-type': 'text/html' } }),
    () => new Response('export {}', { headers: { 'content-type': 'application/octet-stream' } }),
  ]) {
    await assert.rejects(verifyAgentChat({ origin: 'https://station.test', log: () => {}, fetchImpl: async url =>
      url.pathname === '/chat/chat.mjs' ? broken() : chatAsset(url.pathname),
    }), /Agent chat/);
  }
});

test('production verification requires the relay app privacy headers, CSP and actual page', async () => {
  for (const change of [
    response => response.headers.delete('cache-control'),
    response => response.headers.delete('referrer-policy'),
    response => response.headers.delete('x-content-type-options'),
    response => response.headers.set('content-security-policy', "default-src *; script-src 'unsafe-inline'"),
  ]) {
    await assert.rejects(verifyAgentChat({ origin: 'https://station.test', log: () => {}, fetchImpl: async url => {
      const response = chatAsset(url.pathname);
      if (url.pathname === '/chat/') change(response);
      return response;
    } }), /Agent chat/);
  }
  await assert.rejects(verifyAgentChat({ origin: 'https://station.test', log: () => {}, fetchImpl: async url => {
    const response = chatAsset(url.pathname);
    return url.pathname === '/chat/' ? new Response('<!doctype html><html>RTC</html>', { headers: response.headers }) : response;
  } }), /expected asset/);
});
