// Deploy every relay one at a time: trigger its deploy hook, wait for the
// platform (Coolify only, when COOLIFY_API_TOKEN is set), then wait until the
// relay cluster is healthy before touching the next one. Any failure stops the
// run, so later relays keep serving the previous image.
//
// Hook URLs are secrets (a deploy hook is usually its own credential): they
// are never printed. Hooks are referred to as "relay hook <i>/<n>".
import { pathToFileURL } from 'node:url';
import { deployCoolify, isCoolifyDeployURL } from './deploy-coolify.mjs';
import { settingsFromEnv, waitForHealth } from './verify-station.mjs';

/**
 * The relay deploy hooks, in deploy order.
 *
 * RELAY_DEPLOY_HOOKS is the only source: one URL per line; blank lines and
 * surrounding whitespace are ignored.
 */
export function relayHooksFromEnv(env = process.env) {
  return (env.RELAY_DEPLOY_HOOKS ?? '')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean);
}

/** Replace every spelling of a hook URL in text with a placeholder. */
export function redact(text, hook) {
  let out = String(text);
  const spellings = new Set([hook]);
  try {
    spellings.add(new URL(hook).href);
  } catch {
    // Not a URL: only the raw string can appear.
  }
  for (const spelling of spellings) {
    if (spelling) out = out.split(spelling).join('<relay hook>');
  }
  return out;
}

/** Trigger a generic deploy hook (no platform-specific status to wait for). */
export async function triggerHook(hookURL, { fetchImpl = fetch } = {}) {
  let url;
  try {
    url = new URL(hookURL);
  } catch {
    throw new Error('the hook is not a valid URL');
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new Error('the hook must be an http(s) URL');
  }
  const response = await fetchImpl(url, {
    method: 'POST',
    signal: AbortSignal.timeout(30_000),
    redirect: 'error',
  });
  if (!response.ok) throw new Error(`the hook returned HTTP ${response.status}`);
}

export async function deployRelays({
  hooks,
  token,
  health,
  fetchImpl = fetch,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  log = console.log,
  deploy = deployCoolify,
  trigger = triggerHook,
  wait = waitForHealth,
}) {
  if (!hooks.length) {
    throw new Error('RELAY_DEPLOY_HOOKS is required: set it to the relay deploy URLs, one per line');
  }
  const total = hooks.length;
  // With the token every hook goes through the Coolify API: check them all
  // before triggering any, so a bad later line can't stop a half-done rollout.
  if (token) {
    for (const [index, hook] of hooks.entries()) {
      if (!isCoolifyDeployURL(hook)) {
        throw new Error(`relay hook ${index + 1}/${total} is not a Coolify /api/v1/deploy?uuid=... URL`);
      }
    }
  }
  for (const [index, hook] of hooks.entries()) {
    const label = `relay hook ${index + 1}/${total}`;
    const safeLog = line => log(`${label}: ${redact(line, hook)}`);
    try {
      if (token) {
        safeLog('deploying and waiting for Coolify');
        await deploy({ webhookURL: hook, token, fetchImpl, sleep, log: safeLog });
      } else {
        safeLog('triggering (no COOLIFY_API_TOKEN: not waiting for the platform, only for /health)');
        await trigger(hook, { fetchImpl });
      }
      safeLog('waiting for relay health');
      await wait({ ...health, fetchImpl, sleep, log: safeLog });
    } catch (error) {
      const rest = total - index - 1;
      const skipped = rest ? `; ${rest} later relay hook(s) not triggered` : '';
      throw new Error(`${label} failed: ${redact(error?.message ?? error, hook)}${skipped}`);
    }
  }
  log(`All ${total} relay hook(s) deployed`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const run = async () => {
    const hooks = relayHooksFromEnv();
    await deployRelays({
      hooks,
      token: process.env.COOLIFY_API_TOKEN,
      health: settingsFromEnv(),
    });
  };
  run().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
