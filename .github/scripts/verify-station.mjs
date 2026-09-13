import { randomUUID } from 'node:crypto';

const origin = process.env.STATION_URL || 'https://station.agora.build';
for (const path of ['/', '/health']) {
  const response = await fetch(new URL(path, origin), { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}`);
  if (path === '/health') {
    const health = await response.json();
    if (health.status !== 'ok') throw new Error('Relay health is not ok');
    console.log(`Relay health: ${health.status}; vault store: ${health.vault_store}`);
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
