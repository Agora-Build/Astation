import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import test from 'node:test';
import { readToken, settingsFromEnv, verifyAccountProvider } from './check-account-verifier.mjs';

const settings = {
  endpoint: 'https://identity.example.test/userinfo',
  subjectField: 'account_id',
  accessToken: 'private-test-access-token',
};

function provider(body, status = 200) {
  return async (_url, options) => options.headers.Authorization === `Bearer ${settings.accessToken}`
    ? new Response(JSON.stringify(body), { status })
    : new Response('rejected', { status: 401 });
}

test('refuses unsafe or incomplete endpoint settings before any request', () => {
  const env = {
    AGORA_ACCOUNT_USERINFO_URL: settings.endpoint,
    AGORA_ACCOUNT_SUBJECT_FIELD: settings.subjectField,
  };
  for (const endpoint of ['http://identity.example.test', 'https://user:password@identity.example.test', 'https://identity.example.test/#fragment', 'invalid']) {
    assert.throws(() => settingsFromEnv({ ...env, AGORA_ACCOUNT_USERINFO_URL: endpoint }));
  }
  assert.throws(() => settingsFromEnv({}));
  assert.throws(() => settingsFromEnv({ ...env, AGORA_ACCOUNT_SUBJECT_FIELD: ' account_id ' }));
  assert.throws(() => settingsFromEnv({ ...env, AGORA_ACCOUNT_AUTH_TIME_FIELD: ' auth_time ' }));
});

test('checks invalid tokens first and never sends the real token to an endpoint that accepts them', async () => {
  const requests = [];
  await assert.rejects(verifyAccountProvider({
    ...settings,
    fetchImpl: async (_url, options) => {
      requests.push(options);
      return new Response('{"account_id":"untrusted"}');
    },
  }), /Invalid-token check returned HTTP 200/);
  assert.equal(requests.length, 1);
  assert.notEqual(requests[0].headers.Authorization, `Bearer ${settings.accessToken}`);
  assert.equal(requests[0].method, 'GET');
  assert.equal(requests[0].redirect, 'error');
  assert.ok(requests[0].signal instanceof AbortSignal);
});

test('accepts valid response fields without returning credentials or account IDs', async () => {
  const result = await verifyAccountProvider({
    ...settings,
    authTimeField: 'auth_time',
    fetchImpl: provider({ account_id: ' permanent-private-account ', auth_time: 1791662400 }),
  });
  assert.deepEqual(result, { authenticationTimeChecked: true });
  assert.deepEqual(await verifyAccountProvider({
    ...settings,
    fetchImpl: provider({ account_id: 'permanent-private-account' }),
  }), { authenticationTimeChecked: false });
});

test('rejects valid-token HTTP errors and hides provider response contents', async () => {
  for (const status of [401, 403, 500]) {
    await assert.rejects(verifyAccountProvider({
      ...settings,
      fetchImpl: provider({ error: settings.accessToken }, status),
    }), { message: `Valid-token check returned HTTP ${status}` });
  }
});

test('rejects nested, numeric, blank, and oversized subjects, matching the relay UTF-8 byte limit', async () => {
  for (const body of [null, ['account'], {}, { data: { account_id: 'account' } }, { account_id: 123 }, { account_id: ' ' }, { account_id: 'a'.repeat(513) }, { account_id: '\u00e9'.repeat(257) }]) {
    await assert.rejects(verifyAccountProvider({ ...settings, fetchImpl: provider(body) }));
  }
  assert.deepEqual(await verifyAccountProvider({
    ...settings,
    fetchImpl: provider({ account_id: '\u00e9'.repeat(256) }),
  }), { authenticationTimeChecked: false });
});

test('requires usable authentication time when the offline-grouping field is configured', async () => {
  for (const auth_time of [undefined, '1791662400', 1791662400.5, Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(verifyAccountProvider({
      ...settings,
      authTimeField: 'auth_time',
      fetchImpl: provider({ account_id: 'account', auth_time }),
    }), /integer authentication time/);
  }
});

test('redacts network and JSON parse failures', async () => {
  await assert.rejects(verifyAccountProvider({
    ...settings,
    fetchImpl: async () => { throw new Error(`request failed: ${settings.accessToken}`); },
  }), { message: 'Userinfo request failed, timed out, or attempted a redirect' });
  await assert.rejects(verifyAccountProvider({
    ...settings,
    fetchImpl: async (_url, options) => options.headers.Authorization === `Bearer ${settings.accessToken}`
      ? new Response(`invalid JSON containing ${settings.accessToken}`)
      : new Response('', { status: 403 }),
  }), { message: 'Userinfo response is not readable JSON' });
});

test('reads a piped token with a newline and rejects multiline or oversized input', async () => {
  assert.equal(await readToken(Readable.from(['private-', 'test-access-token\n'])), settings.accessToken);
  for (const raw of ['', 'token\nsecond-token', 'token\u0000', 'a'.repeat(16 * 1024 + 1)]) {
    await assert.rejects(readToken(Readable.from([raw])));
  }
  await assert.rejects(readToken({ isTTY: true }), /Pipe the access token/);
});
