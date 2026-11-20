import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const revision = value => typeof value === 'string' && /^[0-9a-f]{40}$/.test(value);
const target = value => typeof value === 'string' && value.trim().length > 0 && value.length <= 2048;

export function deploymentContextName(origin, sha) {
  if (!target(origin) || !revision(sha)) throw new Error('Invalid deployment context');
  return `station-deployment-${createHash('sha256').update(origin).digest('hex')}-${sha}`;
}

export function webappTree(sha, { cwd = process.cwd() } = {}) {
  if (!revision(sha)) throw new Error('Invalid deployment revision');
  return execFileSync('git', ['rev-parse', '--verify', `${sha}:webapp`], {
    cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
}

export async function webappDeployment({
  event = process.env.GITHUB_EVENT_NAME,
  sha = process.env.GITHUB_SHA,
  repository = process.env.GITHUB_REPOSITORY,
  origin = process.env.STATION_URL,
  token = process.env.GITHUB_TOKEN,
  fetchImpl = fetch,
  tree = webappTree,
} = {}) {
  if (event === 'workflow_dispatch') return { deploy: true, reason: 'Manual deployment' };
  if (event !== 'push' || !revision(sha) ||
      !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository ?? '') || !token ||
      !target(origin)) {
    return { deploy: true, reason: 'No confirmed deployment comparison' };
  }
  try {
    // Compare with the last successful rollout, not the preceding commit:
    // a failed rollout may have left an earlier webapp running.
    const url = `https://api.github.com/repos/${repository}/actions/workflows/deploy-station.yml/runs?branch=main&status=success&per_page=1`;
    const settings = () => ({
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' },
      redirect: 'error', signal: AbortSignal.timeout(15_000),
    });
    const response = await fetchImpl(url, settings());
    if (!response.ok) throw new Error('Deployment history unavailable');
    const runs = (await response.json()).workflow_runs;
    const previous = Array.isArray(runs) ? runs[0] : undefined;
    if (!previous || previous.conclusion !== 'success' || previous.head_branch !== 'main' ||
        !revision(previous.head_sha) || !Number.isSafeInteger(previous.id) || previous.id <= 0) {
      throw new Error('No successful deployment');
    }
    // Only the deploy job can record its actual destination after public
    // verification. A run title can reflect variables before a queued job starts.
    const artifactsResponse = await fetchImpl(
      `https://api.github.com/repos/${repository}/actions/runs/${previous.id}/artifacts?per_page=100`, settings());
    if (!artifactsResponse.ok) throw new Error('Deployment context unavailable');
    const artifacts = (await artifactsResponse.json()).artifacts;
    const expected = deploymentContextName(origin, previous.head_sha);
    if (!Array.isArray(artifacts) || !artifacts.some(item => item.name === expected && item.expired === false)) {
      throw new Error('No confirmed deployment to this Station');
    }
    const before = tree(previous.head_sha), after = tree(sha);
    if (!revision(before) || !revision(after)) throw new Error('Source tree unavailable');
    return before === after
      ? { deploy: false, reason: 'Webapp source matches the last successful deployment' }
      : { deploy: true, reason: 'Webapp source changed since the last successful deployment' };
  } catch {
    // Uncertain history must not suppress an update. Do not log API responses
    // or exceptions that may contain authorization or deployment metadata.
    return { deploy: true, reason: 'No confirmed deployment comparison' };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!process.env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required');
  if (process.argv[2] === '--record' && process.argv.length === 4) {
    const origin = process.env.STATION_URL, sha = process.env.GITHUB_SHA;
    const name = deploymentContextName(origin, sha);
    writeFileSync(process.argv[3], JSON.stringify({ version: 1, origin, sha }) + '\n');
    appendFileSync(process.env.GITHUB_OUTPUT, `artifact=${name}\n`);
  } else if (process.argv.length === 2) {
    const result = await webappDeployment();
    console.log(`${result.deploy ? 'Deploy' : 'Keep'} webapp: ${result.reason}`);
    appendFileSync(process.env.GITHUB_OUTPUT, `deploy=${result.deploy}\n`);
  } else {
    throw new Error('Invalid deployment context arguments');
  }
}
