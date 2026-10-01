import assert from 'node:assert/strict';
import test from 'node:test';
import { deployRelays, redact, relayHooksFromEnv, triggerHook } from './deploy-relays.mjs';

const A = 'https://coolify.example/api/v1/deploy?uuid=relay-a&force=false';
const B = 'https://coolify.example/api/v1/deploy?uuid=relay-b&force=false';
const C = 'https://render.example/deploy/srv-c?key=secret-c';
const D = 'https://coolify.example/api/v1/deploy?uuid=relay-d';
const health = { origin: 'https://station.test', minReplicas: 0, requireRedis: false };

test('RELAY_DEPLOY_HOOKS: one per line, in order, blanks and whitespace ignored', () => {
  assert.deepEqual(relayHooksFromEnv({ RELAY_DEPLOY_HOOKS: `\n  ${B}  \r\n\n\t${A}\n${C}\n   \n` }).hooks, [B, A, C]);
  // It wins over the older secrets.
  assert.deepEqual(
    relayHooksFromEnv({ RELAY_DEPLOY_HOOKS: C, COOLIFY_RELAY_SERVER_WEBHOOK_URL: A, COOLIFY_RELAY_B_WEBHOOK_URL: B }).hooks,
    [C],
  );
});

test('falls back to the older secrets when RELAY_DEPLOY_HOOKS is empty or unset', () => {
  for (const RELAY_DEPLOY_HOOKS of [undefined, '', '  \n\n ']) {
    assert.deepEqual(relayHooksFromEnv({ RELAY_DEPLOY_HOOKS, COOLIFY_RELAY_SERVER_WEBHOOK_URL: A }).hooks, [A]);
    assert.deepEqual(
      relayHooksFromEnv({ RELAY_DEPLOY_HOOKS, COOLIFY_RELAY_SERVER_WEBHOOK_URL: A, COOLIFY_RELAY_B_WEBHOOK_URL: B }).hooks,
      [A, B],
    );
    assert.deepEqual(
      relayHooksFromEnv({ RELAY_DEPLOY_HOOKS, COOLIFY_RELAY_SERVER_WEBHOOK_URL: A, COOLIFY_RELAY_B_WEBHOOK_URL: '' }).hooks,
      [A],
    );
  }
  // Like the old workflow: relay-b alone is not enough.
  assert.deepEqual(relayHooksFromEnv({ COOLIFY_RELAY_B_WEBHOOK_URL: B }).hooks, []);
  assert.deepEqual(relayHooksFromEnv({}).hooks, []);
});

function recorder() {
  const events = [];
  const logs = [];
  return {
    events,
    logs,
    options: {
      health,
      sleep: async () => {},
      log: line => logs.push(line),
      deploy: async ({ webhookURL, token, log }) => {
        events.push(['coolify', webhookURL, token]);
        log(`Coolify deployment for ${webhookURL} queued`);
      },
      trigger: async hook => events.push(['trigger', hook]),
      wait: async ({ origin, log }) => {
        events.push(['health', origin]);
        log('Relay healthy');
      },
    },
  };
}

test('deploys in order with a health wait after each hook', async () => {
  const { events, options } = recorder();
  await deployRelays({ ...options, hooks: [A, B], token: 'tok' });
  assert.deepEqual(events, [
    ['coolify', A, 'tok'],
    ['health', 'https://station.test'],
    ['coolify', B, 'tok'],
    ['health', 'https://station.test'],
  ]);
});

test('waits for Coolify only when COOLIFY_API_TOKEN is set', async () => {
  for (const token of [undefined, '']) {
    const { events, options } = recorder();
    await deployRelays({ ...options, hooks: [C, A], token });
    assert.deepEqual(events, [
      ['trigger', C],
      ['health', 'https://station.test'],
      ['trigger', A],
      ['health', 'https://station.test'],
    ]);
  }
});

test('a failed deploy or health wait stops the run', async () => {
  const deployFails = recorder();
  deployFails.options.deploy = async ({ webhookURL }) => {
    deployFails.events.push(['coolify', webhookURL]);
    throw new Error(`Coolify deployment ended with status: failed (${webhookURL})`);
  };
  await assert.rejects(
    deployRelays({ ...deployFails.options, hooks: [A, B, D], token: 'tok' }),
    error => {
      assert.match(error.message, /^relay hook 1\/3 failed: Coolify deployment ended with status: failed/);
      assert.match(error.message, /2 later relay hook\(s\) not triggered/);
      assert.ok(!error.message.includes('coolify.example'), error.message);
      return true;
    },
  );
  assert.deepEqual(deployFails.events, [['coolify', A]]);

  const unhealthy = recorder();
  unhealthy.options.wait = async () => {
    unhealthy.events.push(['health']);
    throw new Error('Relay did not become healthy: relay status is draining');
  };
  await assert.rejects(
    deployRelays({ ...unhealthy.options, hooks: [C, A], token: '' }),
    /relay hook 1\/2 failed: Relay did not become healthy: relay status is draining; 1 later/,
  );
  assert.deepEqual(unhealthy.events, [['trigger', C], ['health']]);

  const last = recorder();
  last.options.wait = async () => {
    throw new Error('Relay did not become healthy: no response');
  };
  await assert.rejects(deployRelays({ ...last.options, hooks: [A], token: 'tok' }), error => {
    assert.equal(error.message, 'relay hook 1/1 failed: Relay did not become healthy: no response');
    return true;
  });
});

test('no hook URL appears in any log line or error', async () => {
  const { logs, options } = recorder();
  await deployRelays({ ...options, hooks: [A, D], token: 'tok' });
  await deployRelays({ ...options, hooks: [C], token: '' });
  const text = logs.join('\n');
  for (const secret of [A, C, D, 'relay-a', 'relay-d', 'secret-c', 'coolify.example', 'render.example']) {
    assert.ok(!text.includes(secret), `log leaked ${secret}:\n${text}`);
  }
  assert.match(text, /relay hook 1\/2: Coolify deployment for <relay hook> queued/);
  assert.match(text, /relay hook 2\/2: Relay healthy/);

  // An unparseable hook isn't echoed either.
  await assert.rejects(triggerHook('not a url secret-xyz'), error => {
    assert.ok(!error.message.includes('secret-xyz'));
    return true;
  });
  assert.equal(redact(`GET ${new URL(A).href} failed`, A), 'GET <relay hook> failed');
});

test('no hooks configured is an error', async () => {
  const { options } = recorder();
  await assert.rejects(deployRelays({ ...options, hooks: [], token: 'tok' }), /No relay deploy hook configured/);
});

test('triggerHook POSTs without following redirects and checks the status', async () => {
  const requests = [];
  await triggerHook(C, {
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), ...init });
      return new Response('{}');
    },
  });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, C);
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].redirect, 'error');
  await assert.rejects(
    triggerHook(C, { fetchImpl: async () => new Response('no', { status: 404 }) }),
    error => error.message === 'the hook returned HTTP 404',
  );
  await assert.rejects(triggerHook('ftp://x.example/deploy'), /http\(s\)/);
});

test('with the token, every hook is checked before any is triggered', async () => {
  for (const bad of [C, 'not a url', 'https://coolify.example/api/v1/deploy', 'ftp://coolify.example/api/v1/deploy?uuid=x']) {
    const { events, options } = recorder();
    await assert.rejects(deployRelays({ ...options, hooks: [A, B, bad], token: 'tok' }), error => {
      assert.equal(error.message, 'relay hook 3/3 is not a Coolify /api/v1/deploy?uuid=... URL');
      return true;
    });
    assert.deepEqual(events, [], 'nothing may be triggered');
  }
  // Without the token any http(s) hook is fine.
  const { events, options } = recorder();
  await deployRelays({ ...options, hooks: [A, C], token: '' });
  assert.deepEqual(events.map(([kind]) => kind), ['trigger', 'health', 'trigger', 'health']);
});

test('the older COOLIFY_* secrets still require the token', async () => {
  for (const token of [undefined, '']) {
    const { events, logs, options } = recorder();
    await assert.rejects(
      deployRelays({ ...options, hooks: [A, B], token, fromFallback: true }),
      /COOLIFY_API_TOKEN is required with COOLIFY_RELAY_SERVER_WEBHOOK_URL/,
    );
    assert.deepEqual(events, []);
    assert.deepEqual(logs, []);
  }
  const { events, options } = recorder();
  await deployRelays({ ...options, hooks: [A], token: 'tok', fromFallback: true });
  assert.deepEqual(events.map(([kind]) => kind), ['coolify', 'health']);
});
