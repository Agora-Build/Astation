#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, readFile, realpath, writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';

// Upload only verified model artifacts. Hatch reads secrets itself; never print them.
const [directory, envFile, suppliedPrefix] = process.argv.slice(2);
if (!directory || !envFile) throw new Error('Usage: publish-transcription-model.mjs <installed-model-directory> <hatch-env-file> [prefix]');
const profiles = {
  'parakeet-eou-120m-320ms-v1': { resource: 'transcription-model', licenseName: 'LICENSE.html', marker: 'NVIDIA Open Model License',
    attribution: 'Original model: NVIDIA\nhttps://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1\nCoreML conversion: FluidInference\nhttps://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml' },
  'whisper-large-v3-turbo-coreml-v1': { resource: 'whisper-large-v3-turbo-coreml-v1', licenseName: 'LICENSE.txt', marker: 'MIT License',
    attribution: 'Original model: OpenAI Whisper large-v3 Turbo\nhttps://github.com/openai/whisper\nCoreML conversion: Argmax\nhttps://huggingface.co/argmaxinc/whisperkit-coreml\nTokenizer: openai/whisper-large-v3, revision 06f233fe06e710322aca913c1bc4249a0d71fce1' },
  'whisper-large-v3-coreml-v1': { resource: 'whisper-large-v3-coreml-v1', licenseName: 'LICENSE.txt', marker: 'MIT License',
    attribution: 'Original model: OpenAI Whisper large-v3\nhttps://github.com/openai/whisper\nCoreML conversion: Argmax\nhttps://huggingface.co/argmaxinc/whisperkit-coreml\nTokenizer: openai/whisper-large-v3, revision 06f233fe06e710322aca913c1bc4249a0d71fce1' },
};
const manifest = JSON.parse(await readFile(join(directory, 'installed.json'), 'utf8'));
const profile = profiles[manifest.id];
if (!profile || manifest.schemaVersion !== 1 || !Array.isArray(manifest.files)) throw new Error('Unexpected model manifest');
const pinned = JSON.parse(await readFile(new URL(`../Sources/Menubar/Resources/${profile.resource}.json`, import.meta.url), 'utf8'));
const prefix = suppliedPrefix ?? `astation/models/${manifest.id}`;
if (!/^astation\/models\/[a-zA-Z0-9_/-]+$/.test(prefix) || prefix.includes('..')) throw new Error('Unsafe publication prefix');
const env = await readFile(envFile, 'utf8');
const publicURL = env.match(/^HATCH_PUBLIC_URL\s*=\s*["']?([^\s"']+)/m)?.[1]?.replace(/\/$/, '');
const base = new URL(publicURL);
if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) throw new Error('Hatch requires a credential-free HTTPS public URL');
if (manifest.revision !== pinned.revision || manifest.licenseURL !== pinned.licenseURL) throw new Error('Only the pinned model revision can be published');
if (new Set(manifest.files.map(file => file.path)).size !== manifest.files.length ||
    manifest.files.some(file => !pinned.files.some(pin => pin.path === file.path) && ![profile.licenseName, 'ATTRIBUTION.txt'].includes(file.path))) throw new Error('Unexpected model files');
async function digest(stream) {
  const hash = createHash('sha256');
  let bytes = 0;
  for await (const chunk of stream) { hash.update(chunk); bytes += chunk.length; }
  return { bytes, sha256: hash.digest('hex') };
}
const root = await realpath(directory);
for (const file of pinned.files) {
  if (!/^[A-Za-z0-9_./-]+$/.test(file.path) || file.path.split('/').some(part => !part || part === '.' || part === '..')) throw new Error('Unsafe model path');
  const installed = manifest.files.find(item => item.path === file.path);
  if (!installed || installed.bytes !== file.bytes || installed.sha256 !== file.sha256) throw new Error(`Unexpected installed file: ${file.path}`);
  const local = join(root, file.path), attributes = await lstat(local);
  if (!attributes.isFile() || attributes.isSymbolicLink() || !(await realpath(local)).startsWith(`${root}/`)) throw new Error('Unsafe installed file');
  const verified = await digest(createReadStream(local));
  if (verified.bytes !== file.bytes || verified.sha256 !== file.sha256) throw new Error(`Integrity check failed: ${file.path}`);
}
const licenseResponse = await fetch(manifest.licenseURL);
if (!licenseResponse.ok) throw new Error(`Model license: HTTP ${licenseResponse.status}`);
const license = await licenseResponse.text();
if (!license.includes(profile.marker) || license.length > 1_000_000) throw new Error('Unexpected model license response');
await writeFile(join(directory, profile.licenseName), license);
await writeFile(join(directory, 'ATTRIBUTION.txt'), `${manifest.name}\n\n${profile.attribution}\nRevision: ${manifest.revision}\nLicense: ${profile.marker}\n${manifest.licenseURL}\n\nDistributed by Agora Build for Astation. These are unmodified pinned CoreML conversion artifacts.\n`);
manifest.files = pinned.files.map(file => ({ ...file }));
manifest.totalBytes = pinned.totalBytes;
for (const file of manifest.files) file.url = `${publicURL}/${prefix}/${file.path}`;
for (const path of [profile.licenseName, 'ATTRIBUTION.txt']) {
  const bytes = await readFile(join(directory, path));
  manifest.files.push({ path, url: `${publicURL}/${prefix}/${path}`, bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex') });
  manifest.totalBytes += bytes.length;
}
const publishedManifest = join(directory, 'transcription-model.json');
await writeFile(publishedManifest, `${JSON.stringify(manifest, null, 2)}\n`);
const paths = [...manifest.files.map(file => file.path), 'transcription-model.json'];
for (const path of paths) {
  const parent = dirname(path);
  const target = `/${prefix}${parent === '.' ? '' : `/${parent}`}`;
  let response = await fetch(`${publicURL}/${prefix}/${path}`);
  if (response.status === 404) {
    const result = spawnSync('hatch', ['--env-file', envFile, 'push', join(directory, path), '--path', target], { stdio: 'inherit' });
    if (result.status !== 0) throw new Error(`Hatch failed for ${path}; no overwrite was attempted.`);
    response = await fetch(`${publicURL}/${prefix}/${path}`);
  }
  if (!response.ok) throw new Error(`Public mirror unavailable for ${path}: HTTP ${response.status}`);
  const remote = await digest(response.body);
  const local = await digest(createReadStream(join(directory, path)));
  if (remote.bytes !== local.bytes || remote.sha256 !== local.sha256) throw new Error(`Public mirror checksum mismatch: ${path}`);
  console.log(`Verified public download: ${path}`);
}
console.log(`Published manifest: ${publicURL}/${prefix}/transcription-model.json`);
