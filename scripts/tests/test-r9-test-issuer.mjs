import assert from 'node:assert/strict';
import { createHash, createPublicKey, randomBytes, verify } from 'node:crypto';
import test from 'node:test';
import { startIssuer } from '../r9-test-issuer.mjs';

test('loopback fixture requires consent, PKCE and exact bindings; refresh tokens rotate', async () => {
  const fixture = await startIssuer({ resource: 'http://127.0.0.1:58431' });
  try {
    const random = () => randomBytes(32).toString('base64url');
    const verifier = random(), state = random(), nonce = random();
    const fields = { response_type: 'code', client_id: fixture.clientID, resource: fixture.resource,
      redirect_uri: 'http://127.0.0.1:58432/callback', code_challenge_method: 'S256',
      code_challenge: createHash('sha256').update(verifier).digest('base64url'), state, nonce,
      scope: `openid offline_access ${fixture.scope}` };
    const post = (path, body) => fetch(fixture.issuer + path, { method: 'POST', redirect: 'manual',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body) });
    const consent = async changes => {
      const response = await fetch(`${fixture.issuer}/authorize?${new URLSearchParams({ ...fields, ...changes })}`, { redirect: 'manual' });
      assert.equal(response.status, 200);
      const id = (await response.text()).match(/name="request" value="([A-Za-z0-9_-]+)"/)[1];
      const approved = await post('/authorize', { request: id });
      assert.equal(approved.status, 303);
      const location = new URL(approved.headers.get('location'));
      assert.equal(location.searchParams.get('state'), state);
      assert.equal((await post('/authorize', { request: id })).status, 400);
      return location.searchParams.get('code');
    };
    for (const change of [{ redirect_uri: 'https://example.com/callback' }, { code_challenge_method: 'plain' }, { resource: 'http://127.0.0.1:9' }]) {
      assert.equal((await fetch(`${fixture.issuer}/authorize?${new URLSearchParams({ ...fields, ...change })}`)).status, 400);
    }
    const tokenFields = { grant_type: 'authorization_code', client_id: fixture.clientID, resource: fixture.resource,
      redirect_uri: fields.redirect_uri, code_verifier: verifier };
    const badCode = await consent();
    assert.equal((await post('/token', { ...tokenFields, code: badCode, code_verifier: random() })).status, 400);
    assert.equal((await post('/token', { ...tokenFields, code: badCode })).status, 400);
    const code = await consent();
    const response = await post('/token', { ...tokenFields, code });
    assert.equal(response.status, 200);
    const tokens = await response.json();
    const discovery = await (await fetch(`${fixture.issuer}/.well-known/openid-configuration`)).json();
    const { keys } = await (await fetch(discovery.jwks_uri)).json();
    for (const [name, typ, aud] of [['access_token', 'at+jwt', fixture.resource], ['id_token', 'JWT', fixture.clientID]]) {
      const [header, body, signature] = tokens[name].split('.');
      assert.equal(JSON.parse(Buffer.from(header, 'base64url')).typ, typ);
      const claims = JSON.parse(Buffer.from(body, 'base64url'));
      assert.equal(claims.aud, aud);
      assert.match(claims.sub, /^acct_[a-z0-9]{26}$/);
      assert.ok(verify('sha256', Buffer.from(`${header}.${body}`),
        { key: createPublicKey({ key: keys[0], format: 'jwk' }), dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
    }
    assert.equal((await post('/token', { ...tokenFields, code })).status, 400);
    const refresh = { grant_type: 'refresh_token', client_id: fixture.clientID, resource: fixture.resource, refresh_token: tokens.refresh_token };
    assert.equal((await post('/token', { ...refresh, resource: 'http://127.0.0.1:9' })).status, 400);
    const renewed = await post('/token', refresh);
    assert.equal(renewed.status, 200);
    assert.ok((await renewed.json()).refresh_token !== tokens.refresh_token);
    assert.equal((await post('/token', refresh)).status, 400);
  } finally { await fixture.close(); }
});
