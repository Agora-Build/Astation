# Live transcription

## Scope

- Local, incremental English captions for one or more explicitly checked sources:
  microphone, system audio, or selected apps, with per-source engines and labels.
  All-system and selected-app output capture are alternative modes.
- FluidAudio 0.17.5 with Parakeet EOU 120M, 320 ms streaming configuration.
- WhisperKit 0.18.0 with pinned Whisper large-v3 Turbo and full large-v3 CoreML
  profiles, offline tokenizers, and bounded speech windows. User-switchable
  low-latency/faster-multilingual/accuracy-oriented tradeoff labels.
- Explicit, cancellable downloads into Astation's Application Support model cache.
- A pinned file manifest with sizes and SHA-256 hashes; allow GitHub/CDN manifests.
- A standalone Live Transcription settings item with controls for model download,
  local/cloud provider, source checkboxes, language,
  translation target, start/stop, copy, and transcript export.
- Opt-in Agora Real-Time STT and translated captions, authenticated with
  AccessToken2 from the user's existing signed-in Agora project. No customer
  secret or certificate is embedded in the app or passed on command lines.
- A child process owns the cloud RTC engine so it cannot replace the call engine.
- Custom OpenAI-compatible multipart HTTP endpoints, model/language/window
  controls, optional endpoint-isolated Keychain keys, explicit upload consent,
  refused redirects, bounded responses, and immediate Stop cancellation.
- Save Transcript TXT/JSON and optional full-session TXT/JSONL auto-save to
  `~/Documents/Astation/Transcripts`; saving is independent of recording.
- Resample only the transcription branch. Never change original audio files.
- Independent recording/transcription Start and Stop controls; either can run
  alone or together. Stop Recording retains capture while captions still need it.
- One Agora session per checked cloud source, with explicit multi-source billing
  disclosure before upload. One local model instance per checked local source.
- Draggable nonactivating floating captions, movable across external monitors;
  multiline text with a rolling 20-second history. Enabled by default, toggleable
  during transcription, and hidden automatically when no captions remain.

## Work

1. Add downloadable model assets, integrity checks, local streaming adapter,
   bounded PCM delivery, and transcript state.
2. Add Agora agent lifecycle, isolated custom-audio publisher, caption decoding,
   and token renewal. Start only after explicit cloud consent.
3. Build settings UI and recorder lifecycle integration; add practical tests.
4. Validate local inference with a public speech fixture, without microphone
   capture. Cloud paid-service validation requires an enabled project and consent.
5. Finish build/tests, then upload verified artifacts with Hatch using
   `~/.config/hatch/astation.env`. Verify public hashes before switching the
   bundled URLs to the mirror. Never overwrite existing CDN artifacts blindly.

## Current validation

Real inference passed for Parakeet, Whisper Turbo, and full Whisper large-v3 on
this Mac using the public whisper.cpp JFK
speech fixture. It recognized the expected sentence with no microphone capture
or cloud session. The dedicated transcription suite includes
original-file preservation, cloud token renewal/cancellation with HTTP stubs,
multiline expiry and external-monitor coordinate preservation. Full-suite
validation passed 389 tests with real inference enabled (concurrent Parakeet
sources and sequential Whisper profiles). The final suite passes 391 tests with
the two opt-in inference tests skipped, including endpoint schema/security,
cancelled uploads, transcript file permissions/full history/final flush, model
switching, discrete aggregate downmix, and bounded microphone replacement.
Debug/release
builds pass. The cloud helper also
passes an EOF-only process smoke check without creating an RTC engine/channel.

Hatch's Astation configuration names the `astation` R2 bucket and public base
`https://artifacts.agora.build`. The initial upload returned `NoSuchBucket`;
no artifacts were uploaded. Retrying after the completed build returned the same
error. Keep the pinned upstream URLs until publication and public-download
verification succeed. The existing Astation Dev is running; do not replace or
restart it without consent. Transcription remains an integrated Astation feature.

A temporary copy of the entire Astation app was previously packaged as
`.build/Astation Transcription.app` and passed deep/strict ad-hoc signature
verification. It is not a separate transcription product. Use the normal
Astation bundle for future interactive testing. The running Astation Dev is
unchanged.

## References

- https://github.com/FluidInference/FluidAudio/tree/v0.17.5
- https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
- https://github.com/argmaxinc/WhisperKit/tree/v0.18.0
- https://huggingface.co/argmaxinc/whisperkit-coreml
- https://developers.openai.com/api/docs/guides/speech-to-text
- https://docs.agora.io/en/realtime-media/speech-to-text/get-started/quickstart
- https://docs.agora.io/en/realtime-media/speech-to-text/build/start-transcribing-and-translating/enable-service
- https://docs.agora.io/en/realtime-media/speech-to-text/build/start-transcribing-and-translating/translation
- https://docs.agora.io/en/realtime-media/speech-to-text/build/process-transcription-data/parse-data
