import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const revision = value => typeof value === 'string' && /^[0-9a-f]{40}$/.test(value);

export function webappTree(sha, { cwd = process.cwd() } = {}) {
  if (!revision(sha)) throw new Error('Invalid deployment revision');
  return execFileSync('git', ['rev-parse', '--verify', `${sha}:webapp`], {
    cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
}

async function boundedJSON(response) {
  const reader = response.body.getReader();
  const chunks = [];
  let count = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > 4096) throw new Error('Oversize source metadata');
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally {
    await reader.cancel();
  }
}

export async function webappDeployment({
  event = process.env.GITHUB_EVENT_NAME,
  sha = process.env.GITHUB_SHA,
  origin = process.env.STATION_URL,
  fetchImpl = fetch,
  tree = webappTree,
} = {}) {
  if (event === 'workflow_dispatch') return { deploy: true, reason: 'Manual deployment' };
  try {
    const url = new URL(origin);
    if (event !== 'push' || !revision(sha) || url.protocol !== 'https:' || url.origin !== origin) {
      throw new Error('No confirmed deployment context');
    }
    const expected = tree(sha);
    if (!revision(expected)) throw new Error('Source tree unavailable');
    // Read the frontend that is actually serving this origin. A unique query
    // and no-store response avoid treating an old CDN response as live state.
    url.pathname = '/.well-known/astation-webapp-build.json';
    url.searchParams.set('probe', randomUUID());
    const response = await fetchImpl(url, {
      headers: { 'Cache-Control': 'no-cache', Pragma: 'no-cache' },
      redirect: 'error', signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok || !response.headers.get('cache-control')?.toLowerCase().split(',').map(s => s.trim()).includes('no-store') ||
        ![null, '0'].includes(response.headers.get('age')) ||
        ['HIT', 'STALE', 'UPDATING'].includes(response.headers.get('cf-cache-status')?.toUpperCase())) {
      await response.body?.cancel();
      throw new Error('No live frontend source');
    }
    const metadata = await boundedJSON(response);
    if (!metadata || Object.keys(metadata).sort().join(',') !== 'source_tree,version' ||
        metadata.version !== 1 || !revision(metadata.source_tree)) throw new Error('Unknown frontend source');
    return metadata.source_tree === expected
      ? { deploy: false, reason: 'The running frontend already serves this webapp source' }
      : { deploy: true, reason: 'The running frontend serves a different webapp source' };
  } catch {
    return { deploy: true, reason: 'No confirmed live frontend comparison' };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!process.env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required');
  const result = await webappDeployment();
  console.log(`${result.deploy ? 'Deploy' : 'Keep'} webapp: ${result.reason}`);
  appendFileSync(process.env.GITHUB_OUTPUT, `deploy=${result.deploy}\n`);
}
