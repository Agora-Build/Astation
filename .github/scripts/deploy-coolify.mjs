import { pathToFileURL } from 'node:url';

export async function deployCoolify({
  webhookURL,
  token,
  fetchImpl = fetch,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  log = console.log,
  maxPolls = 90,
}) {
  if (!webhookURL || !token) {
    throw new Error('COOLIFY_WEBHOOK_URL and COOLIFY_API_TOKEN are required');
  }
  const webhook = new URL(webhookURL);
  if (webhook.pathname !== '/api/v1/deploy' || !webhook.searchParams.get('uuid')) {
    throw new Error('Expected a Coolify /api/v1/deploy?uuid=... URL');
  }
  const request = async url => {
    const response = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(30_000),
      redirect: 'error',
    });
    if (!response.ok) {
      throw new Error(`Coolify API returned HTTP ${response.status}`);
    }
    return response.json();
  };

  const queued = await request(webhook);
  const deployments = queued.deployments;
  if (!Array.isArray(deployments) || deployments.length !== 1 || !deployments[0].deployment_uuid) {
    throw new Error('Coolify did not return one queued deployment');
  }
  const uuid = deployments[0].deployment_uuid;
  const statusURL = new URL(`/api/v1/deployments/${encodeURIComponent(uuid)}`, webhook);
  log(`Coolify deployment ${uuid} queued`);
  let previousStatus;
  for (let attempt = 0; attempt < maxPolls; attempt++) {
    const { status } = await request(statusURL);
    if (status !== previousStatus) log(`Coolify deployment status: ${status}`);
    previousStatus = status;
    if (status === 'finished') return uuid;
    if (!['queued', 'in_progress'].includes(status)) {
      throw new Error(`Coolify deployment ended with status: ${status}`);
    }
    await sleep(10_000);
  }
  throw new Error('Timed out waiting for Coolify deployment');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  deployCoolify({
    webhookURL: process.env.COOLIFY_WEBHOOK_URL,
    token: process.env.COOLIFY_API_TOKEN,
  }).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
