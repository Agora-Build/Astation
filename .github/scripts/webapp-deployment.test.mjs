import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { deploymentContextName, webappDeployment, webappTree } from './webapp-deployment.mjs';

const directory = mkdtempSync(join(tmpdir(), 'station-webapp-deploy-'));
const git = (...args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8' }).trim();
const commit = message => {
  git('add', '.');
  git('-c', 'user.name=Deployment Test', '-c', 'user.email=deployment@example.test', 'commit', '-qm', message);
  return git('rev-parse', 'HEAD');
};
git('init', '-q');
mkdirSync(join(directory, 'webapp'));
writeFileSync(join(directory, 'webapp', 'nginx.conf'), 'original proxy');
const deployed = commit('Deployed webapp');
writeFileSync(join(directory, 'relay.rs'), 'relay update');
const relayOnly = commit('Only the relay changed');
writeFileSync(join(directory, 'webapp', 'nginx.conf'), 'new proxy');
const webappChanged = commit('Proxy changed in an unsuccessful rollout');
writeFileSync(join(directory, 'relay.rs'), 'another relay update');
const nextPush = commit('Relay changed after the unsuccessful rollout');
writeFileSync(join(directory, 'webapp', 'nginx.conf'), 'original proxy');
const rollback = commit('Revert frontend source after an unsuccessful rollout');
test.after(() => rmSync(directory, { recursive: true, force: true }));

function options(sha = relayOnly) {
  return {
    event: 'push', sha, repository: 'Agora-Build/Astation', token: 'test-token', origin: 'https://station.example',
    runNumber: '9', attempt: '1',
    tree: value => webappTree(value, { cwd: directory }),
    fetchImpl: async (url, settings) => {
      assert.equal(settings.headers.Authorization, 'Bearer test-token');
      assert.equal(settings.redirect, 'error');
      if (url.endsWith('/actions/runs/123/artifacts?per_page=100')) {
        return { ok: true, json: async () => ({ artifacts: [
          { name: deploymentContextName('https://station.example', deployed), expired: false },
        ] }) };
      }
      assert.match(url, /\/actions\/workflows\/deploy-station.yml\/runs\?branch=main&per_page=100$/);
      return { ok: true, json: async () => ({ workflow_runs: [
        { id: 123, run_number: 8, status: 'completed', conclusion: 'success', head_branch: 'main', head_sha: deployed },
      ] }) };
    },
  };
}

test('a relay-only change keeps the unchanged webapp running', async () => {
  assert.equal((await webappDeployment(options())).deploy, false);
});

test('webapp changes deploy, including after an unsuccessful intermediate rollout', async () => {
  assert.equal((await webappDeployment(options(webappChanged))).deploy, true);
  assert.equal((await webappDeployment(options(nextPush))).deploy, true);
  assert.equal(webappTree(webappChanged, { cwd: directory }), webappTree(nextPush, { cwd: directory }));
});

test('manual deployment always deploys without relying on history', async () => {
  assert.equal((await webappDeployment({
    ...options(), event: 'workflow_dispatch',
    fetchImpl: () => assert.fail('Manual deployment must not query history'),
  })).deploy, true);
});

test('a partial or canceled newer rollout cannot hide a required rollback', async () => {
  assert.equal(webappTree(deployed, { cwd: directory }), webappTree(rollback, { cwd: directory }));
  for (const conclusion of ['failure', 'cancelled', null]) {
    assert.equal((await webappDeployment({
      ...options(rollback), fetchImpl: async () => ({ ok: true, json: async () => ({ workflow_runs: [
        { id: 124, run_number: 8, status: conclusion ? 'completed' : 'in_progress', conclusion, head_branch: 'main', head_sha: webappChanged },
        { id: 123, run_number: 7, status: 'completed', conclusion: 'success', head_branch: 'main', head_sha: deployed },
      ] }) }),
      tree: () => assert.fail('An uncertain newer attempt cannot use an older baseline'),
    })).deploy, true);
  }
  assert.equal((await webappDeployment({
    ...options(), attempt: '2', fetchImpl: () => assert.fail('A retry always redeploys'),
  })).deploy, true);
});

test('current and future queued runs cannot become their own deployment baseline', async () => {
  const original = options().fetchImpl;
  assert.equal((await webappDeployment({
    ...options(), fetchImpl: async (url, settings) => {
      const result = await original(url, settings);
      if (url.includes('/artifacts?')) return result;
      const body = await result.json();
      body.workflow_runs.unshift(
        { id: 125, run_number: 10, status: 'queued', head_branch: 'main', head_sha: nextPush },
        { id: 124, run_number: 9, status: 'in_progress', head_branch: 'main', head_sha: relayOnly });
      return { ok: true, json: async () => body };
    },
  })).deploy, false);
});

test('a changed destination or missing, expired or wrong-revision context requires webapp deployment', async () => {
  assert.equal((await webappDeployment({ ...options(), origin: 'https://production.example' })).deploy, true);
  for (const artifacts of [[],
    [{ name: deploymentContextName('https://station.example', deployed), expired: true }],
    [{ name: deploymentContextName('https://station.example', relayOnly), expired: false }],
  ]) {
    const original = options().fetchImpl;
    assert.equal((await webappDeployment({
      ...options(), fetchImpl: (url, settings) => url.includes('/artifacts?')
        ? { ok: true, json: async () => ({ artifacts }) } : original(url, settings),
    })).deploy, true);
  }
});

test('missing or uncertain deployment history never suppresses the webapp', async () => {
  for (const fetchImpl of [
    async () => { throw new Error('Private upstream diagnostic'); },
    async () => ({ ok: false, status: 403 }),
    async () => ({ ok: true, json: async () => ({ workflow_runs: [] }) }),
    async () => ({ ok: true, json: async () => ({ workflow_runs: [
      { conclusion: 'failure', head_branch: 'main', head_sha: deployed },
    ] }) }),
    async () => ({ ok: true, json: async () => ({ workflow_runs: [
      { conclusion: 'success', head_branch: 'other', head_sha: deployed },
    ] }) }),
    async () => ({ ok: true, json: async () => ({ workflow_runs: [
      { conclusion: 'success', head_branch: 'main', head_sha: 'not-a-revision' },
    ] }) }),
  ]) {
    assert.deepEqual(await webappDeployment({ ...options(), fetchImpl }), {
      deploy: true, reason: 'No confirmed deployment comparison',
    });
  }
  assert.equal((await webappDeployment({ ...options(), tree: () => { throw new Error('Missing old commit'); } })).deploy, true);
  assert.equal((await webappDeployment({ ...options(), tree: () => '' })).deploy, true);
});

test('unconfirmed workflow context cannot skip an update or send the token elsewhere', async () => {
  for (const change of [{ token: '' }, { sha: 'invalid' }, { repository: '../another' }, { origin: '' }, { event: 'other' },
    { runNumber: '0' }, { attempt: 'bad' }]) {
    assert.equal((await webappDeployment({
      ...options(), ...change, fetchImpl: () => assert.fail('Invalid context must not request history'),
    })).deploy, true);
  }
  assert.throws(() => webappTree('--help', { cwd: directory }), /Invalid deployment revision/);
});

test('the real manual entrypoint writes the force-deploy output without account credentials', () => {
  const output = join(directory, 'workflow-output');
  execFileSync(process.execPath, [fileURLToPath(new URL('./webapp-deployment.mjs', import.meta.url))], {
    env: { GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_OUTPUT: output },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.equal(readFileSync(output, 'utf8'), 'deploy=true\n');
});

test('the real recording entrypoint binds the actual deployment job destination and revision', () => {
  const output = join(directory, 'context-output'), context = join(directory, 'context.json');
  const origin = 'https://another-station.example';
  execFileSync(process.execPath, [fileURLToPath(new URL('./webapp-deployment.mjs', import.meta.url)), '--record', context], {
    env: { STATION_URL: origin, GITHUB_SHA: relayOnly, GITHUB_OUTPUT: output },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.deepEqual(JSON.parse(readFileSync(context, 'utf8')), { version: 1, origin, sha: relayOnly });
  assert.equal(readFileSync(output, 'utf8'), `artifact=${deploymentContextName(origin, relayOnly)}\n`);
  assert.notEqual(deploymentContextName(origin, relayOnly), deploymentContextName(origin, deployed));
  assert.notEqual(deploymentContextName(origin, relayOnly), deploymentContextName('https://station.example', relayOnly));
});
