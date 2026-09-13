import assert from 'node:assert/strict';
import test from 'node:test';
import { deployCoolify } from './deploy-coolify.mjs';

function harness(responses) {
  const requests = [];
  return {
    requests,
    options: {
      webhookURL: 'https://coolify.example/api/v1/deploy?uuid=station',
      token: 'test-token',
      sleep: async () => {},
      log: () => {},
      fetchImpl: async (url, options) => {
        requests.push({ url: String(url), ...options });
        assert.ok(responses.length, 'Unexpected API request');
        return responses.shift();
      },
    },
  };
}
const json = body => new Response(JSON.stringify(body));
const queued = () => json({ deployments: [{ deployment_uuid: 'deployment-123' }] });

test('authenticates deployment and waits for successful completion', async () => {
  const { requests, options } = harness([
    queued(), json({ status: 'queued' }), json({ status: 'in_progress' }), json({ status: 'finished' }),
  ]);
  assert.equal(await deployCoolify(options), 'deployment-123');
  assert.equal(requests.length, 4);
  assert.equal(requests[1].url, 'https://coolify.example/api/v1/deployments/deployment-123');
  for (const request of requests) {
    assert.equal(request.headers.Authorization, 'Bearer test-token');
    assert.equal(request.redirect, 'error');
  }
});

test('fails when Coolify rejects authentication', async () => {
  const { options } = harness([new Response('Unauthenticated', { status: 401 })]);
  await assert.rejects(deployCoolify(options), /HTTP 401/);
});

test('does not treat a failed or cancelled deployment as success', async () => {
  for (const status of ['failed', 'cancelled-by-user']) {
    const { options } = harness([queued(), json({ status })]);
    await assert.rejects(deployCoolify(options), new RegExp(status));
  }
});

test('rejects an empty queue and bounds deployment waiting', async () => {
  const empty = harness([json({ deployments: [] })]);
  await assert.rejects(deployCoolify(empty.options), /did not return one queued deployment/);
  const pending = harness([queued(), json({ status: 'in_progress' })]);
  await assert.rejects(deployCoolify({ ...pending.options, maxPolls: 1 }), /Timed out/);
});
