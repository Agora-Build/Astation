#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Generates the pinned manifest, not the weights. A CDN mirror must retain these hashes.
const argumentsList = process.argv.slice(2);
const modelIndex = argumentsList.indexOf('--model');
const selected = modelIndex < 0 ? 'parakeet' : argumentsList.splice(modelIndex, 2)[1];
const profiles = {
  parakeet: { repo: 'FluidInference/parakeet-realtime-eou-120m-coreml', revision: '40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355',
    folder: '320ms', id: 'parakeet-eou-120m-320ms-v1', name: 'Parakeet EOU 120M (English, 320 ms)',
    resource: 'transcription-model', licenseURL: 'https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/' },
  'whisper-turbo': { repo: 'argmaxinc/whisperkit-coreml', revision: '0f63a7800b00dd0226abd051b906c246e1907482',
    folder: 'openai_whisper-large-v3-v20240930_turbo', id: 'whisper-large-v3-turbo-coreml-v1', name: 'Whisper large-v3 Turbo (multilingual)',
    resource: 'whisper-large-v3-turbo-coreml-v1', licenseURL: 'https://raw.githubusercontent.com/openai/whisper/v20240930/LICENSE' },
  'whisper-large': { repo: 'argmaxinc/whisperkit-coreml', revision: '0f63a7800b00dd0226abd051b906c246e1907482',
    folder: 'openai_whisper-large-v3', id: 'whisper-large-v3-coreml-v1', name: 'Whisper large-v3 (multilingual)',
    resource: 'whisper-large-v3-coreml-v1', licenseURL: 'https://raw.githubusercontent.com/openai/whisper/v20240930/LICENSE' },
};
const profile = profiles[selected];
if (!profile) throw new Error('Use --model parakeet, whisper-turbo, or whisper-large');
const { repo, revision, folder } = profile;
const output = argumentsList[0] ?? fileURLToPath(new URL(`../Sources/Menubar/Resources/${profile.resource}.json`, import.meta.url));
const mirror = argumentsList[1]?.replace(/\/$/, '');
let next = `https://huggingface.co/api/models/${repo}/tree/${revision}/${folder}?recursive=true&expand=true`;
const entries = [];
while (next) {
  const response = await fetch(next);
  if (!response.ok) throw new Error(`Model listing: HTTP ${response.status}`);
  entries.push(...await response.json());
  next = response.headers.get('link')?.match(/<([^>]+)>; rel="next"/)?.[1];
}
const files = [];
for (const entry of entries) {
  if (entry.type !== 'file') continue;
  const relative = entry.path.slice(folder.length + 1);
  if (selected === 'parakeet' && !/^(?:[^/]+\.mlmodelc\/|vocab\.json$)/.test(relative)) continue;
  if (selected !== 'parakeet' && !/^(?:[^/]+\.mlmodelc\/|config\.json$|generation_config\.json$)/.test(relative)) continue;
  const upstream = `https://huggingface.co/${repo}/resolve/${revision}/${entry.path}`;
  let sha256 = entry.lfs?.oid;
  if (!sha256) {
    if (entry.size > 10_000_000) throw new Error(`Missing upstream checksum: ${entry.path}`);
    const response = await fetch(upstream);
    if (!response.ok) throw new Error(`Metadata download: HTTP ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length !== entry.size) throw new Error(`Size mismatch: ${entry.path}`);
    sha256 = createHash('sha256').update(bytes).digest('hex');
  }
  const path = relative;
  files.push({ path, url: mirror ? `${mirror}/${path}` : upstream, bytes: entry.size, sha256 });
}
if (selected === 'parakeet') {
  if (!files.some(file => file.path === 'vocab.json') || files.length < 16) throw new Error('Incomplete model listing');
} else {
  const tokenizerRepo = 'openai/whisper-large-v3';
  const tokenizerRevision = '06f233fe06e710322aca913c1bc4249a0d71fce1';
  for (const name of ['tokenizer.json', 'tokenizer_config.json', 'config.json']) {
    const url = `https://huggingface.co/${tokenizerRepo}/resolve/${tokenizerRevision}/${name}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Tokenizer download: HTTP ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    const path = `tokenizer/${name}`;
    files.push({ path, url: mirror ? `${mirror}/${path}` : url, bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex') });
  }
  for (const name of ['AudioEncoder', 'TextDecoder', 'MelSpectrogram']) {
    if (!files.some(file => file.path === `${name}.mlmodelc/weights/weight.bin`)) throw new Error('Incomplete Whisper model listing');
  }
}
files.sort((a, b) => a.path.localeCompare(b.path));
const manifest = {
  schemaVersion: 1,
  id: profile.id,
  name: profile.name,
  revision,
  licenseURL: profile.licenseURL,
  totalBytes: files.reduce((sum, file) => sum + file.bytes, 0),
  files,
};
await mkdir(dirname(output), { recursive: true });
await writeFile(output, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Generated ${files.length} files, ${(manifest.totalBytes / 1e6).toFixed(1)} MB: ${output}`);
