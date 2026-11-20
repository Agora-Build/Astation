import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { webappDeployment, webappTree } from './webapp-deployment.mjs';

const directory = mkdtempSync(join(tmpdir(), 'station-webapp-deploy-'));
const git = (...args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8' }).trim();
const commit = message => {
  git('add', '.');
  git('-c', 'user.name=Deployment Test', '-c', 'user.email=deployment@example.test', '-c', 'commit.gpgsign=false', 'commit', '-qm', message);
  return git('rev-parse', 'HEAD');
};
git('init', '-q');
mkdirSync(join(directory, 'webapp'));
writeFileSync(join(directory, 'webapp', 'nginx.conf'), 'original proxy');
const deployed = commit('Original frontend');
writeFileSync(join(directory, 'relay.rs'), 'relay update');
const relayOnly = commit('Only the relay changed');
writeFileSync(join(directory, 'webapp', 'nginx.conf'), 'new proxy');
const changed = commit('Frontend changed');
writeFileSync(join(directory, 'webapp', 'nginx.conf'), 'original proxy');
const rollback = commit('Revert frontend after a partial rollout');
test.after(() => rmSync(directory, { recursive: true, force: true }));
const tree = sha => webappTree(sha, { cwd: directory });
const response = (source = tree(deployed)) => new Response(JSON.stringify({ version: 1, source_tree: source }), {
  headers: { 'Cache-Control': 'no-store' },
});
const options = (sha = relayOnly) => ({
  event: 'push', sha, origin: 'https://station.example', tree,
  fetchImpl: async () => response(),
});

test('the running frontend is checked through actual HTTP with cache bypass and bounded metadata', async () => {
  let requests = 0;
  const server = createServer((request, result) => {
    requests++;
    assert.match(request.url, /^\/\.well-known\/astation-webapp-build\.json\?probe=[a-f0-9-]+$/);
    assert.equal(request.headers['cache-control'], 'no-cache');
    assert.equal(request.headers.authorization, undefined);
    result.writeHead(200, { 'Cache-Control': 'no-store', 'Content-Type': 'application/json' });
    result.end(JSON.stringify({ version: 1, source_tree: tree(deployed) }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const local = `http://127.0.0.1:${server.address().port}`;
    const result = await webappDeployment({ ...options(), fetchImpl: (url, settings) => {
      assert.equal(url.origin, 'https://station.example');
      assert.equal(settings.redirect, 'error');
      return fetch(new URL(url.pathname + url.search, local), settings);
    } });
    assert.equal(result.deploy, false);
    assert.equal(requests, 1);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('relay-only changes keep the frontend; source changes and rollback after a partial rollout deploy', async () => {
  assert.equal((await webappDeployment(options())).deploy, false);
  assert.equal((await webappDeployment(options(changed))).deploy, true);
  assert.equal(tree(deployed), tree(rollback));
  assert.equal((await webappDeployment({ ...options(rollback), fetchImpl: async () => response(tree(changed)) })).deploy, true);
});

test('each probe targets the selected origin with a fresh nonce and no redirect or token', async () => {
  const probes = [];
  for (const origin of ['https://station.example', 'https://custom.example:8443']) {
    assert.equal((await webappDeployment({ ...options(), origin, fetchImpl: async (url, settings) => {
      assert.equal(url.origin, origin);
      assert.equal(settings.redirect, 'error');
      assert.equal(Object.hasOwn(settings.headers, 'Authorization'), false);
      probes.push(url.searchParams.get('probe'));
      return response();
    } })).deploy, false);
  }
  assert.equal(new Set(probes).size, 2);
});

test('manual repair always deploys without relying on frontend state', async () => {
  assert.equal((await webappDeployment({ ...options(), event: 'workflow_dispatch',
    fetchImpl: () => assert.fail('Manual deployment must not probe'),
  })).deploy, true);
});

test('missing, cached, malformed, oversized or unavailable live metadata never suppresses an update', async () => {
  const valid = JSON.stringify({ version: 1, source_tree: tree(deployed) });
  for (const fetchImpl of [
    async () => { throw new Error('Upstream diagnostic'); },
    async () => new Response('', { status: 404 }),
    async () => new Response('', { status: 503 }),
    async () => new Response(valid),
    async () => new Response(valid, { headers: { 'Cache-Control': 'no-store', Age: '1' } }),
    async () => new Response(valid, { headers: { 'Cache-Control': 'no-store', 'CF-Cache-Status': 'HIT' } }),
    async () => new Response(' '.repeat(4097), { headers: { 'Cache-Control': 'no-store' } }),
    async () => new Response('not json', { headers: { 'Cache-Control': 'no-store' } }),
    async () => response(''),
    async () => new Response(JSON.stringify({ version: 2, source_tree: tree(deployed) }), { headers: { 'Cache-Control': 'no-store' } }),
    async () => new Response(JSON.stringify({ version: 1, source_tree: tree(deployed), extra: true }), { headers: { 'Cache-Control': 'no-store' } }),
  ]) {
    assert.deepEqual(await webappDeployment({ ...options(), fetchImpl }), {
      deploy: true, reason: 'No confirmed live frontend comparison',
    });
  }
});

test('invalid deployment context cannot probe another origin or invoke an arbitrary git command', async () => {
  for (const change of [{ sha: '--help' }, { origin: 'http://station.example' },
    { origin: 'https://user:secret@station.example' }, { origin: 'https://station.example/path' },
    { origin: 'https://station.example?query' }, { origin: 'https://station.example#fragment' }, { event: 'other' }]) {
    assert.equal((await webappDeployment({ ...options(), ...change,
      fetchImpl: () => assert.fail('Invalid context must not probe'),
    })).deploy, true);
  }
  assert.throws(() => tree('--help'), /Invalid deployment revision/);
});

test('unavailable desired source forces deployment', async () => {
  for (const unavailable of [() => '', () => { throw new Error('Missing git object'); }]) {
    assert.equal((await webappDeployment({ ...options(), tree: unavailable })).deploy, true);
  }
});

test('the real manual entrypoint forces deployment without account credentials', () => {
  const output = join(directory, 'workflow-output');
  execFileSync(process.execPath, [fileURLToPath(new URL('./webapp-deployment.mjs', import.meta.url))], {
    env: { GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_OUTPUT: output },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.equal(readFileSync(output, 'utf8'), 'deploy=true\n');
});
