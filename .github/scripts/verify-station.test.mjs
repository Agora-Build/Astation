import assert from 'node:assert/strict';
import test from 'node:test';
import { healthProblems, settingsFromEnv, waitForHealth } from './verify-station.mjs';

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
  // Defaults match today's production relay: no redis/replicas fields.
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
  });
  assert.deepEqual(
    settingsFromEnv({ STATION_URL: 'https://x.test', STATION_MIN_REPLICAS: '2', STATION_REQUIRE_REDIS: '1' }),
    { origin: 'https://x.test', minReplicas: 2, requireRedis: true },
  );
  assert.throws(() => settingsFromEnv({ STATION_MIN_REPLICAS: 'two' }), /STATION_MIN_REPLICAS/);
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
