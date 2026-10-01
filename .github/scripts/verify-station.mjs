import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export function healthProblems(health, { minReplicas = 0, requireRedis = false } = {}) {
  const problems = [];
  if (health.status !== 'ok') problems.push(`relay status is ${health.status}`);
  // Atem Memory sync must be durable in production: an in-memory store
  // (DATABASE_URL missing) would silently lose every account's data on restart.
  if (health.knowledge_store !== 'postgres') {
    problems.push(`relay knowledge store is ${health.knowledge_store}, expected postgres`);
  }
  // Several replicas share rooms and sessions only through Redis.
  if (requireRedis && health.redis !== 'ok') {
    problems.push(`relay redis is ${health.redis ?? 'missing'}, expected ok`);
  }
  // minReplicas 0 = not checked (a relay that predates multi-replica reports no count).
  const replicas = Number(health.replicas ?? 0);
  if (minReplicas > 0 && replicas < minReplicas) {
    problems.push(`relay reports ${replicas} live replica(s), expected at least ${minReplicas}`);
  }
  return problems;
}

export function settingsFromEnv(env = process.env) {
  const raw = env.STATION_MIN_REPLICAS || '0';
  const minReplicas = Number(raw);
  if (!Number.isInteger(minReplicas) || minReplicas < 0) {
    throw new Error(`STATION_MIN_REPLICAS must be a non-negative integer, got ${raw}`);
  }
  return {
    origin: env.STATION_URL || 'https://station.agora.build',
    minReplicas,
    requireRedis: env.STATION_REQUIRE_REDIS === '1',
  };
}

async function fetchHealth(origin, fetchImpl) {
  const response = await fetchImpl(new URL('/health', origin), { signal: AbortSignal.timeout(30_000) });
  const health = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, health };
}

/** Poll /health until the cluster is healthy (after a relay deploy). */
export async function waitForHealth({
  origin,
  minReplicas,
  requireRedis,
  fetchImpl = fetch,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  log = console.log,
  attempts = 36,
}) {
  let last = 'no response';
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const { ok, status, health } = await fetchHealth(origin, fetchImpl);
      const problems = ok
        ? healthProblems(health, { minReplicas, requireRedis })
        : [`/health returned HTTP ${status}`];
      if (problems.length === 0) {
        log(`Relay healthy: redis ${health.redis ?? 'n/a'}, ${health.replicas ?? 'n/a'} live replica(s)`);
        return health;
      }
      last = problems.join('; ');
    } catch (error) {
      last = error.message;
    }
    log(`Waiting for relay health: ${last}`);
    await sleep(5_000);
  }
  throw new Error(`Relay did not become healthy: ${last}`);
}

export async function verifyStation({ origin, minReplicas, requireRedis }) {
  for (const path of ['/', '/health']) {
    const response = await fetch(new URL(path, origin), { signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}`);
    if (path === '/health') {
      const health = await response.json();
      const problems = healthProblems(health, { minReplicas, requireRedis });
      if (problems.length) throw new Error(`Relay health: ${problems.join('; ')}`);
      console.log(
        `Relay health: ${health.status}; vault store: ${health.vault_store}; ` +
          `knowledge store: ${health.knowledge_store}; redis: ${health.redis ?? 'n/a'}; replicas: ${health.replicas ?? 'n/a'}`,
      );
    } else if (!(await response.text()).toLowerCase().includes('<!doctype html>')) {
      throw new Error('Station did not return the webapp HTML');
    }
    console.log(`${path}: HTTP ${response.status}`);
  }

  for (const path of ['/ws', '//ws']) {
    const url = new URL(origin);
    url.pathname = path;
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('role', 'astation');
    url.searchParams.set('code', `astation-${randomUUID()}`);
    await new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      const timer = setTimeout(() => {
        reject(new Error('Identity WebSocket connection timed out'));
        socket.close();
      }, 15_000);
      socket.addEventListener('open', () => {
        clearTimeout(timer);
        console.log(`Identity WebSocket ${path}: connected`);
        socket.close();
        resolve();
      }, { once: true });
      socket.addEventListener('error', () => {
        clearTimeout(timer);
        reject(new Error('Identity WebSocket connection failed'));
      }, { once: true });
    });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const run = async () => {
    const settings = settingsFromEnv();
    if (process.argv.includes('--wait-health')) {
      await waitForHealth(settings);
    } else {
      await verifyStation(settings);
    }
  };
  run().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
