import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const tokenLimit = 16 * 1024;

export function settingsFromEnv(env = process.env) {
  const endpoint = env.AGORA_ACCOUNT_USERINFO_URL;
  const subjectField = env.AGORA_ACCOUNT_SUBJECT_FIELD;
  const authTimeField = env.AGORA_ACCOUNT_AUTH_TIME_FIELD || undefined;
  if (!endpoint || !subjectField || endpoint.trim() !== endpoint || subjectField.trim() !== subjectField) {
    throw new Error('Set AGORA_ACCOUNT_USERINFO_URL and AGORA_ACCOUNT_SUBJECT_FIELD without surrounding whitespace');
  }
  let url;
  try {
    url = new URL(endpoint);
  } catch {
    throw new Error('AGORA_ACCOUNT_USERINFO_URL must be an absolute HTTPS URL');
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash) {
    throw new Error('Use an HTTPS userinfo URL without embedded credentials or a fragment');
  }
  if (authTimeField && authTimeField.trim() !== authTimeField) {
    throw new Error('AGORA_ACCOUNT_AUTH_TIME_FIELD must not have surrounding whitespace');
  }
  return { endpoint, subjectField, authTimeField };
}

function validateToken(token) {
  if (typeof token !== 'string' || !token || /\s|[\x00-\x1f\x7f]/.test(token) || Buffer.byteLength(token) > tokenLimit) {
    throw new Error('Provide one nonempty access token of at most 16 KiB through standard input');
  }
}

export async function readToken(input = process.stdin) {
  if (input.isTTY) throw new Error('Pipe the access token through standard input; do not pass it as an argument');
  let raw = '';
  input.setEncoding('utf8');
  const timer = setTimeout(() => input.destroy(new Error('Token input timed out')), 10_000);
  try {
    for await (const chunk of input) {
      raw += chunk;
      if (Buffer.byteLength(raw) > tokenLimit + 2) {
        throw new Error('Token input exceeds 16 KiB');
      }
    }
    const token = raw.trim();
    validateToken(token);
    return token;
  } finally {
    clearTimeout(timer);
  }
}

export async function verifyAccountProvider({ endpoint, subjectField, authTimeField, accessToken, fetchImpl = fetch }) {
  validateToken(accessToken);
  async function request(token) {
    try {
      return await fetchImpl(endpoint, {
        method: 'GET',
        headers: { Authorization: `Bearer ${token}` },
        redirect: 'error',
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      // Fetch errors can include URLs or provider details; report only the failure class.
      throw new Error('Userinfo request failed, timed out, or attempted a redirect');
    }
  }

  const invalidResponse = await request(`astation-preflight-invalid-${randomBytes(32).toString('hex')}`);
  await invalidResponse.body?.cancel();
  if (![401, 403].includes(invalidResponse.status)) {
    throw new Error(`Invalid-token check returned HTTP ${invalidResponse.status}; expected 401 or 403`);
  }

  const response = await request(accessToken);
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`Valid-token check returned HTTP ${response.status}`);
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error('Userinfo response is not readable JSON');
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new Error('Userinfo response must be a JSON object with top-level identity fields');
  }
  const subject = Object.hasOwn(body, subjectField) ? body[subjectField] : undefined;
  if (typeof subject !== 'string' || !subject.trim() || Buffer.byteLength(subject.trim()) > 512) {
    throw new Error('Userinfo response lacks a valid top-level permanent account ID string');
  }
  if (authTimeField && (!Object.hasOwn(body, authTimeField) || !Number.isSafeInteger(body[authTimeField]))) {
    throw new Error('Userinfo response lacks an integer authentication time in Unix seconds');
  }
  return { authenticationTimeChecked: Boolean(authTimeField) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const run = async () => {
    if (process.argv.length !== 2) throw new Error('Set verifier settings in the environment and pipe the token through standard input');
    const settings = settingsFromEnv();
    const accessToken = await readToken();
    const result = await verifyAccountProvider({ ...settings, accessToken });
    console.log('Account verifier preflight passed: invalid token rejected; valid token and account ID schema accepted.');
    if (result.authenticationTimeChecked) console.log('Authentication-time schema accepted; fresh sign-in must be checked by the grouping flow.');
    console.log('Confirm permanent account ID semantics with the SSO owner before deploying.');
  };
  run().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
