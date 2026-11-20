import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
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
test.after(() => rmSync(directory, { recursive: true, force: true }));

function options(sha = relayOnly) {
  return {
    event: 'push', sha, repository: 'Agora-Build/Astation', token: 'test-token', origin: 'https://station.example',
    tree: value => webappTree(value, { cwd: directory }),
    fetchImpl: async (url, settings) => {
      assert.match(url, /\/actions\/workflows\/deploy-station.yml\/runs\?branch=main&status=success&per_page=1$/);
      assert.equal(settings.headers.Authorization, 'Bearer test-token');
      assert.equal(settings.redirect, 'error');
      return { ok: true, json: async () => ({ workflow_runs: [
        { conclusion: 'success', head_branch: 'main', head_sha: deployed,
          display_title: `Deploy Station to https://station.example at ${deployed}` },
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

test('a changed destination or an older unbound baseline requires webapp deployment', async () => {
  assert.equal((await webappDeployment({ ...options(), origin: 'https://production.example' })).deploy, true);
  assert.equal((await webappDeployment({
    ...options(), fetchImpl: async () => ({ ok: true, json: async () => ({ workflow_runs: [
      { conclusion: 'success', head_branch: 'main', head_sha: deployed },
    ] }) }),
  })).deploy, true);
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
  for (const change of [{ token: '' }, { sha: 'invalid' }, { repository: '../another' }, { origin: '' }, { event: 'other' }]) {
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
