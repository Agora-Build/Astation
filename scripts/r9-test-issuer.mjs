#!/usr/bin/env node
// Isolated loopback OIDC fixture. Never package or deploy as an account service.
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';

const random = () => randomBytes(32).toString('base64url');
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');

export async function startIssuer({ port = 0, resource, clientID = 'astation-local-r9', scope = 'astation.remote' }) {
  const target = new URL(resource);
  if (target.protocol !== 'http:' || target.hostname !== '127.0.0.1' || target.username || target.password
      || target.search || target.hash || !target.port) throw new Error('Use a loopback relay resource with an explicit port.');
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const kid = random();
  const jwk = { ...publicKey.export({ format: 'jwk' }), kid, use: 'sig', alg: 'ES256' };
  const subject = `ab${randomBytes(13).toString('hex').toUpperCase()}`;
  const pending = new Map(), codes = new Map(), refreshes = new Map();
  let issuer;
  const now = () => Math.floor(Date.now() / 1000);
  const jwt = (claims, typ) => {
    const input = `${encode({ alg: 'ES256', typ, kid })}.${encode({ iss: issuer, sub: subject, iat: now(), exp: now() + 300, ...claims })}`;
    return `${input}.${sign('sha256', Buffer.from(input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  };
  const tokens = (request, includeID) => {
    const refresh = random();
    refreshes.set(refresh, { ...request, deadline: now() + 900 });
    return {
      token_type: 'Bearer', expires_in: 300, refresh_token: refresh,
      access_token: jwt({ aud: resource, client_id: clientID, scope, auth_time: request.authTime }, 'at+jwt'),
      ...(includeID ? { id_token: jwt({ aud: clientID, nonce: request.nonce, auth_time: request.authTime }, 'JWT') } : {}),
    };
  };
  const form = async request => {
    if (request.headers['content-type']?.split(';')[0] !== 'application/x-www-form-urlencoded') throw new Error('form');
    let bytes = '';
    for await (const chunk of request) {
      bytes += chunk;
      if (Buffer.byteLength(bytes) > 8192) throw new Error('size');
    }
    return unique(new URLSearchParams(bytes));
  };
  const unique = fields => {
    if ([...fields.keys()].some(key => fields.getAll(key).length !== 1)) throw new Error('duplicate');
    return Object.fromEntries(fields);
  };
  const reply = (response, status, value) => {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' });
    response.end(JSON.stringify(value));
  };
  const server = createServer(async (request, response) => {
    try {
      if (request.headers.host !== new URL(issuer).host) throw new Error('host');
      for (const map of [pending, codes, refreshes]) {
        for (const [key, value] of map) if (value.deadline <= now()) map.delete(key);
      }
      if ([pending, codes, refreshes].some(map => map.size >= 256)) return reply(response, 503, { error: 'temporarily_unavailable' });
      const url = new URL(request.url, issuer);
      if (request.method === 'GET' && url.pathname === '/.well-known/openid-configuration') {
        return reply(response, 200, { issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${issuer}/token`,
          jwks_uri: `${issuer}/jwks`, response_types_supported: ['code'], subject_types_supported: ['public'],
          id_token_signing_alg_values_supported: ['ES256'], code_challenge_methods_supported: ['S256'],
          token_endpoint_auth_methods_supported: ['none'], grant_types_supported: ['authorization_code', 'refresh_token'] });
      }
      if (request.method === 'GET' && url.pathname === '/jwks') return reply(response, 200, { keys: [jwk] });
      if (request.method === 'GET' && url.pathname === '/authorize') {
        const input = unique(url.searchParams);
        const redirect = new URL(input.redirect_uri);
        if (input.response_type !== 'code' || input.client_id !== clientID || input.resource !== resource
            || input.code_challenge_method !== 'S256' || !/^[A-Za-z0-9_-]{43}$/.test(input.code_challenge ?? '')
            || !/^[A-Za-z0-9_-]{24,256}$/.test(input.state ?? '') || !/^[A-Za-z0-9_-]{24,256}$/.test(input.nonce ?? '')
            || !['openid', 'offline_access', scope].every(value => input.scope?.split(' ').includes(value))
            || redirect.protocol !== 'http:' || redirect.hostname !== '127.0.0.1' || !redirect.port
            || redirect.username || redirect.password || redirect.pathname !== '/callback' || redirect.search || redirect.hash) throw new Error('authorization');
        const id = random();
        pending.set(id, { ...input, deadline: now() + 120 });
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store',
          'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; form-action 'self'; frame-ancestors 'none'" });
        response.end(`<!doctype html><title>Local r9 test account</title><h1>Local r9 integration test</h1><p>This signs in to a temporary test account on this Mac.</p><form method="post" action="/authorize"><input type="hidden" name="request" value="${id}"><button>Authorize local test account</button></form>`);
        return;
      }
      if (request.method === 'POST' && url.pathname === '/authorize') {
        if (request.headers.origin && request.headers.origin !== issuer) throw new Error('origin');
        const input = await form(request), saved = pending.get(input.request);
        if (!saved) throw new Error('authorization');
        pending.delete(input.request);
        const code = random();
        codes.set(code, { ...saved, authTime: now(), deadline: now() + 60 });
        const redirect = new URL(saved.redirect_uri);
        redirect.searchParams.set('code', code); redirect.searchParams.set('state', saved.state);
        response.writeHead(303, { Location: redirect.href, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' });
        response.end(); return;
      }
      if (request.method === 'POST' && url.pathname === '/token') {
        const input = await form(request);
        if (input.client_id !== clientID || input.resource !== resource) throw new Error('binding');
        if (input.grant_type === 'authorization_code') {
          const saved = codes.get(input.code);
          codes.delete(input.code);
          if (!saved || saved.redirect_uri !== input.redirect_uri || !/^[A-Za-z0-9._~-]{43,128}$/.test(input.code_verifier ?? '')
              || createHash('sha256').update(input.code_verifier).digest('base64url') !== saved.code_challenge) throw new Error('grant');
          return reply(response, 200, tokens(saved, true));
        }
        if (input.grant_type === 'refresh_token') {
          const saved = refreshes.get(input.refresh_token);
          refreshes.delete(input.refresh_token);
          if (!saved) throw new Error('grant');
          return reply(response, 200, tokens(saved, false));
        }
      }
      reply(response, 400, { error: 'invalid_request' });
    } catch { reply(response, 400, { error: 'invalid_request' }); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  issuer = `http://127.0.0.1:${server.address().port}`;
  return { issuer, resource, clientID, scope, close: () => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const fixture = await startIssuer({ port: Number(process.env.R9_TEST_ISSUER_PORT ?? 58430),
    resource: process.env.R9_TEST_RESOURCE ?? 'http://127.0.0.1:58431' });
  console.log(`Local test issuer: ${fixture.issuer}\nRelay resource: ${fixture.resource}\nClient: ${fixture.clientID}\nScope: ${fixture.scope}`);
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => { await fixture.close(); process.exit(0); });
}
