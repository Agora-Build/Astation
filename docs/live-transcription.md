# Live transcription and floating captions

Live Transcription is its own Settings sidebar item. Enable audio sources in
Settings > Audio & Recording (or use Configure Audio Sources), then check one or
more sources in Settings > Live Transcription:

- Microphone only, system audio only, or a specific app only.
- Microphone plus all system audio.
- One or more selected apps, optionally with the microphone.

All system audio and selected-app capture remain alternative output modes. Each
checked source gets a separate engine and labeled captions, not a mixed audio
stream. Unchecked enabled sources can still be recorded, but are never sent to a
transcription engine. Original recording files retain their native sample rate,
channels, and samples; each transcription branch converts to 16 kHz mono.

Recording and transcription can run independently or together. Transcription
alone creates no audio files. Start/Stop Transcription does not stop an existing
recording. Stop Recording finalizes the original files but keeps capture running
if captions still need it; Stop Transcription then releases that retained capture.
Stopping captions over an independently started preview leaves that preview
running. Changing the shared source configuration, capture failure, sleep, or
app shutdown stops both.

## Local models

The model picker offers three profiles:

| Profile | Tradeoff | Download | Language |
| --- | --- | --- | --- |
| Parakeet EOU 120M | Low-latency native streaming | 224 MB | English |
| Whisper large-v3 Turbo | Faster multilingual, reduced decoder | 1.64 GB | Selected input language |
| Whisper large-v3 | Accuracy-oriented full decoder, more memory/processing | 3.09 GB | Selected input language |

These labels describe architecture and resource tradeoffs, not measured universal
rankings for accents/noise. Whisper uses WhisperKit 0.18.0 and locally installed
tokenizer files, without runtime fallback downloads. Its rolling windows emit
partials roughly every two seconds and finalize after about 800 ms of silence
or at 24 seconds. Each source has its own bounded window and engine.

The default is on-device English using FluidAudio 0.17.5 and the Parakeet Realtime
EOU 120M CoreML model, 320 ms configuration. This model is designed for streaming
and end-of-utterance detection rather than repeated whole-file inference. Apple
Silicon uses CPU and Neural Engine; Intel falls back to CPU (not hardware-tested).

Click Download Selected Model once for each profile you want to try. The download is explicit,
cancellable, and checked against pinned sizes and SHA-256 hashes. Opening settings
or starting captions does not automatically download models. The cache is
`~/Library/Application Support/Astation/Models/<model-id>`.
Starting local transcription verifies installed files and works offline thereafter.
Failed or cancelled replacement downloads preserve an existing installation.
One download serves every selected source, but each source loads its own model
instance and uses additional memory and processing. Sources are inferred
concurrently; if one fails or cannot keep up, all captions stop with an error
while an otherwise healthy original recording continues.

FluidAudio is Apache-2.0; the **model weights are under the NVIDIA Open Model
License**, not Apache/MIT. See the bundled manifest's license link. The model is
NVIDIA's Parakeet Realtime EOU, converted to CoreML by FluidInference, pinned to
revision `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`.

Whisper models use the MIT license, converted to CoreML by Argmax. Both profiles
pin `argmaxinc/whisperkit-coreml` revision
`0f63a7800b00dd0226abd051b906c246e1907482`; the tokenizer is
`openai/whisper-large-v3` at `06f233fe06e710322aca913c1bc4249a0d71fce1`.
The full profile uses `openai_whisper-large-v3`, not a similarly named reduced
decoder variant. Profile-specific manifests contain every file's size and hash.

Aggregate microphones retain all native lanes in the originals. The transcription
branch explicitly averages discrete input lanes to mono before resampling. Preview
can reconnect a changed microphone format without interrupting other sources or
captions; repeated reconnects are bounded. During recording, a true format change
still stops capture and retains files rather than changing an original track's format.

## Floating window

Floating captions are enabled by default. The nonactivating window supports
wrapped and explicit multiline text, original and translated captions, and a
rolling 20-second history. Partial captions update in place. Each source retains
its own caption identities, even when providers reuse sentence IDs. When multiple
sources are selected, captions show their source name. A changed caption starts
its own 20-second lifetime; duplicate packets do not extend it. Completed
captions remain after Stop until they expire. The window automatically hides when
empty but keeps watching while transcription is live; new speech brings it back.

Drag the background or header to any position on any connected
display, including external monitors. Caption updates preserve the chosen window
origin. The window can appear over full-screen applications without stealing
keyboard focus; clicking its text enables selection without activating Astation.
Double-click a word or drag across words and lines, then use Command-C or
right-click > Copy. The header's Copy button copies the selected text, or all
currently displayed captions if nothing is selected (not the full session transcript).
Selection survives new captions and updates outside the selected text, but clears
if the selected words change or expire. The waiting-for-speech placeholder cannot
be copied. Hide turns off floating captions without stopping transcription,
transcript saving, or recording. Restore using Show Floating Captions in the
Astation menu's Voice Dictation section or Live Transcription settings, or re-enable
the settings checkbox.
An explicit Show works even after all captions expired: it displays a waiting-for-
speech message (or guidance to start transcription) instead of silently remaining
hidden. It does not replay expired captions. The header simply reads LIVE CAPTIONS.

Bind Toggle Floating Captions in Settings > Keyboard Shortcuts to show/hide from
any app. It starts unbound and uses the same conflict checks as other shortcuts.
Toggling after automatic timeout shows the window, rather than disabling captions.
Holding the key triggers only once until release. Showing again retains the last
dragged position, including on an external monitor.
Placement is retained within the current app session, not persisted across restarts.
Long histories scroll inside a bounded-height window, with newest text in view.

## Voice dictation and optional LLM polishing

Settings > Voice Dictation is independent of Live Transcription. Push-to-talk
captures your local microphone while the key is held and finishes when released.
Hands-Free keeps listening until explicitly stopped and processes final utterances
in order. Configure both shortcuts in Keyboard Shortcuts; Hands-Free starts unbound.
Dictation uses the installed local ASR profile and input language selected in Live
Transcription, even if live captions use Agora/custom transcription. No extra RTC
channel or cloud speech session is created for dictation.

Dictation is available when transcription is off, or when only system/app sources
are being transcribed. If live transcription includes the microphone, both dictation
modes are disabled. Switching to mic transcription cancels unfinished dictation
and pending polishing; cancelled text is never silently submitted.

The teal **Polish** dial in Voice Dictation settings and the floating-caption header
controls the same persisted on/off option. It is a binary toggle, not a strength
control. It affects only finalized microphone dictation, not live system/app captions
or original recordings. Changes apply to the next finalized utterance; an already
processing utterance keeps its selected configuration. Polishing defaults off.
When enabled, ASR text is passed to the selected LLM to fix punctuation, grammar,
and fillers while preserving language/meaning; the model has no tools or actions.
Raw ASR and polished results are kept separately in memory. A model can still make
editing mistakes: check captions before using sensitive dictation.

Choose one of four providers:

| Choice | Requirements | Where text goes |
| --- | --- | --- |
| Apple on-device | macOS 26+, eligible Mac, Apple Intelligence enabled/model ready | Apple's local Foundation Models framework |
| Qwen / Ollama / llama.cpp | Separately installed local runtime and model | Configurable localhost-only Chat Completions endpoint |
| Cloud - OpenAI | API key, available model, explicit endpoint-bound text-upload consent | OpenAI Chat Completions |
| Custom | Compatible endpoint/model, optional API key, consent for non-localhost | Your configured endpoint |

Apple's model is compact and managed/downloaded by macOS, not Astation. If it is
unavailable, choose local Qwen explicitly; Astation never silently falls back to cloud.
For example, install/start Ollama separately, run `ollama pull qwen3:4b`, and choose
the local-server option with model `qwen3:4b` and endpoint
`http://localhost:11434/v1/chat/completions`. You can choose a smaller model or point
at llama.cpp instead. Astation does not install/start a runtime or automatically
download LLM weights. Model size, quality, latency, and memory use depend on your Mac
and selected model. Qwen3's `/no_think` instruction requests non-thinking output.

Cloud/custom sends recognized text, not microphone audio. Remote endpoints require
HTTPS and consent for that exact URL; editing the URL invalidates the old consent.
HTTP is permitted only on localhost. Keys are held in an endpoint-bound Keychain
namespace separate from ASR keys, never preferences or logs. Redirects, automatic
retries, tools, and streaming responses are disabled. Requests have a 30-second
timeout and 35-second resource deadline; response bodies are bounded to 1 MB.
Polishing accepts up to 8 KB of ASR text (Apple local: 4 KB), with bounded output.
It is a copy-editing task, not a conversation: greetings and questions remain
greetings and questions, and commands remain dictated commands rather than being
carried out. For example, "hello how are you" becomes "Hello, how are you?".
All providers receive an explicit editing task with JSON-escaped transcript data
and examples. Apple uses guided generation of a transcript-text field instead of
free-form chat output. Polishing does not change the chosen provider/model or enabled outputs.
Empty, refused, truncated, malformed, or nonempty thinking-block responses are not
used. An empty leading Qwen thinking-mode marker is removed before using the text.
Provider retention policies and charges still apply.

Choose independent outputs in **Use result**:

- **Type in active text field** (default on): requires Accessibility access.
  Astation captures the original editable non-password field and verifies its focus,
  contents, and cursor before replacing its selected text. It never presses Return,
  pastes via the clipboard, or sends keystrokes. Missing permission or an unsupported
  or changed field keeps captions available and does not block selected Atem delivery.
- **Send to active Atem** (default off): send a final `voice_command` only if the original
  target is still connected and active. A focus change never reroutes a late result.
  Failed or unavailable Atem delivery does not block typing.

Enable both to use the same result in the text field and Atem; polishing runs once
before delivery to either. Floating captions always receive the result. Turn both
outputs off for transcription/captions only, without typing or sending. Existing
saved single-destination preferences migrate to matching switches without opting
users into another output. Changing outputs during dictation cancels pending delivery.

Polishing failure retains raw captions locally and reports the error; raw text is
never automatically typed/sent as a fallback. Hands-Free polishing is serialized
and bounded to 16 waiting utterances; overload cancels dictation instead of growing
memory without limit. Dictation captions share the floating 20-second history but
are not added to the independent Live Transcription session's export/auto-save files.

HTTP protocol: <https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create>.
Qwen mode reference: <https://qwenlm.github.io/blog/qwen3/>.

## RTC microphone independence

Recording, dictation, and RTC lease the same native microphone capture when they
choose the same physical device. Original PCM and timestamps fan out off the realtime
tap into separate bounded queues. Closing one feature releases only that feature's
lease. Channel join/leave and RTC mute gate publication, not native microphone capture;
RTC's lease can remain listening after leaving a channel until explicitly released.
The menu reports this and offers Release RTC Microphone. App shutdown releases all leases.
Pre-join/pre-unmute queued audio is not replayed into a call.

RTC uses a separate converted 48 kHz mono PCM16 branch and Agora's direct custom-audio
track with `enableAudioProcessing = true`, retaining Agora playback as the echo
reference. AEC, standard noise suppression, and gain control are enabled on this RTC
branch; optional Agora AI noise-reduction modes are available in the menu. None of
these modify original recordings. When screen sharing includes system audio,
Agora's explicit local audio mixer publishes the microphone and stereo screen
track together; mic mute removes only the mic from that mix. Stopping screen
sharing restores direct mic publication without releasing native capture.
Actual speaker/microphone echo quality and AI
noise suppression still need a live Mac call check; unit tests prove lifecycle and
packet routing, not acoustic quality or SDK processing equivalence.

## Saving live transcripts

The in-memory transcript is retained separately (bounded to 2,000 segments or
2 MB). Copy and Save Transcript support timestamped TXT or structured JSON.
Manual exports include the current buffer (including live partials); JSON reports
when it has been truncated. A new session resets that buffer.

Enable Auto-save Transcript to retain the full session on disk independently of
audio recording. The default folder is `~/Documents/Astation/Transcripts` and can
be changed. Each session gets a private timestamp/UUID directory containing:

- `transcript.txt`: finalized captions with timestamp, source, and language. A
  provider's changed final revision is appended as another final event.
- `transcript.jsonl`: changing partial and final events, including translations;
  identical duplicates and late partials after a final are ignored.
- `session.json`: start time and non-secret settings; never an API key.

Directories use mode 0700 and files 0600. Stop flushes final callbacks before
closing files. A save failure reports an error but leaves captions and original
recording running; Save Transcript can save the bounded current buffer elsewhere.
Show Saved opens the latest session folder. No audio file is created by transcription.

## Custom OpenAI-compatible HTTP

Choose Custom - OpenAI-compatible HTTP. Enter the full transcription URL, such as
`https://api.openai.com/v1/audio/transcriptions` or your own compatible server's
endpoint. Astation does not append paths. HTTPS is required; HTTP is allowed only
for `localhost`, `127.0.0.1`, or `::1`. Embedded credentials, query parameters,
and fragments are rejected. Choose the exact model name your server accepts
(`whisper-1` is the default), an input language, and a 5/10/15-second window.

Save Key stores an optional bearer API key in macOS Keychain for that exact URL.
Changing endpoints never sends the old endpoint's key to the new one. Clear Key
removes only the current endpoint's key. Keys are not stored in UserDefaults,
model manifests, transcript exports, logs, or session metadata.

After explicit upload consent, each checked source sends separate speech-gated
multipart requests: `model`, `response_format=json`, base `language` code, and a
mono 16 kHz PCM WAV `file`. Silent input is not uploaded. The response must be JSON
with a string `text` field. This is short-window HTTP transcription, not OpenAI's
Realtime/WebSocket protocol; network and provider latency add to the audio window.
Translation targets remain an Agora-only feature.

Redirects are refused, HTTP bodies are not included in error messages, responses
are limited to 1 MB while being read, and caption text is limited to 64 KiB.
HTTP requests time out after 30 seconds and are not automatically retried.
Stop cancels outstanding work without uploading a final trailing window. The
provider controls retention and charges; original recordings stay local.
Protocol reference: <https://developers.openai.com/api/docs/guides/speech-to-text>.

## Agora cloud and translation

Choose Cloud - Agora Real-Time STT & Translation. Sign in to Astation, select an
Agora project with an App Certificate, and enable Real-Time STT in Agora Console.
English is the default; choose another input language and an optional different
translation target in settings. This uses Agora's Real-Time STT product, not a
generic cloud language model or Conversational AI agent.

Start shows an explicit audio-upload and billing confirmation. Capture permission
must succeed before cloud agents start. Only checked sources are published;
originals stay local. Each source has its own Agora session and isolated publisher,
so selecting more sources can increase charges. Cloud service usage may be billed
by Agora. Stopping captions does not stop an existing recording or an
independently started preview.

An isolated child process per source owns its cloud RTC singleton and custom
audio track, so it does not reset Astation's current call engine. The helper opens neither a
microphone nor a camera and disables playback and remote audio subscriptions.
AccessToken2 tokens come from the existing signed-in project; certificates never
leave the parent, and tokens are passed via stdin, not command-line arguments or
logs. Credentials changing stops cloud transcription.

Publisher tokens refresh and the agent is recreated every 45 minutes; STT 7.x
bot tokens cannot be updated in place. Stop flushes the final short audio packet,
allows up to one second for delayed captions, closes the publisher, and requests
agent leave. Cleanup survives cancellation. An abnormal parent exit causes the
helper's stdin to close; Agora's 30-second channel-idle timeout is a fallback.

## Model publishing

The bundled manifest initially uses pinned public Hugging Face files. An optional
HTTPS Model mirror field accepts a compatible manifest served by GitHub or a
CDN. Embedded credentials, URL query parameters, traversal paths, and unsupported
files are rejected. Do not publish a broken mirror URL as the application default.

Generate an upstream or rewritten manifest with:

```bash
node scripts/prepare-transcription-model.mjs
node scripts/prepare-transcription-model.mjs --model whisper-turbo
node scripts/prepare-transcription-model.mjs --model whisper-large
node scripts/prepare-transcription-model.mjs /tmp/transcription-model.json \
  https://dl.agora.build/astation/models/parakeet-eou-120m-320ms-v1
```

After file-only local validation has downloaded and verified the model, publish
using the Astation Hatch environment (the script never prints credentials):

```bash
node scripts/publish-transcription-model.mjs \
  .build/transcription-validation/parakeet-eou-120m-320ms-v1 \
  /Users/brent/.config/hatch/astation.env
```

The uploader supports all three installed profile directories, verifies the
bundled pinned revision, and streams hashes instead of loading multi-GB weights
into memory. The default prefix is `/astation/models/<model-id>`. The public base
comes from `HATCH_PUBLIC_URL` in that file. The uploader includes the license and
attribution and publishes the manifest last. It checks every public download's
hash and refuses to overwrite conflicting remote files. It can resume matching
files after a partial upload. Switch the bundled manifest only after this passes.

## Validation

```bash
swift test --filter Transcription
swift test --filter 'Dictation|SharedMicrophone|KeyboardShortcut'
swift test
```

Tests cover settings migration, checksums/traversal, failed/cancelled model
downloads, real AVAudioConverter resampling/flush, bounded delivery, original CAF
preservation, concurrent source isolation, partial startup/failure cleanup,
independent recording/transcription Stop controls, standalone settings and
multi-source checkboxes, preview ownership, permission denial,
cloud consent, mocked HTTP authentication/schema, gzip captions, token renewal,
join cancellation, 20-second expiry, duplicates, and floating-window coordinates.
They do not collect live audio or call paid services.

Dictation tests cover PTT final aggregation, Hands-Free ordered/deduplicated delivery,
mic-transcription exclusion/cancellation, key release during setup, raw versus polished
text, all provider request schemas/limits, endpoint-bound consent and Keychain isolation,
failure without external fallback, late-result cancellation, original Atem/text-field
target protection, synchronized Polish controls, and settings/panel snapshots.
Shared-microphone tests cover native sample/rate/channel/timestamp preservation,
reference-counted leases, drop/error propagation, bounded recovery, preview format
replacement, RTC mute/leave/rejoin, and no pre-unmute audio replay.

To test real Apple on-device polishing without capture, typing, or cloud requests
(requires macOS 26+, Apple Intelligence enabled, and the local model ready):

```sh
ASTATION_TEST_APPLE_POLISH=1 swift test --filter AppleDictationPolishingIntegrationTests
```

This opt-in check verifies that greetings, questions, and requests are edited
rather than answered or carried out. Normal CI skips this on-device check.

### Live Mac checklist

1. Preview/record the mic, then join and leave RTC repeatedly. Confirm the waveform
   and local dictation do not restart or disappear. Mute RTC and confirm original
   recordings/captions remain audible. Release RTC Microphone and confirm other leases
   still work; the macOS mic privacy indicator should stop only after the last consumer.
2. Transcribe system/app audio and test both dictation shortcuts. Then select mic
   transcription while holding PTT: unfinished dictation must be cancelled, not sent.
3. Try Polish with Apple Intelligence enabled/model ready, then with a separately
   installed Qwen local server. Disconnect the network for the local checks. Check names,
   numbers, punctuation, language, and latency; no model is guaranteed to edit perfectly.
4. Test cloud/custom only with explicit consent and a valid provider key. Check captions
   first. Simulate an unavailable server: keep raw locally and never type/send a fallback.
5. In a plain text editor, enable active-field output with Accessibility permission.
   Change focus/cursor/text while polishing: no result should be inserted. Password and
   unsupported fields must be rejected. Test supported applications individually.
6. In a two-party RTC speaker call, compare processed echo/noise/level behavior with
   headphones and speakers, including keyboard taps and sudden background noise. Check
   the selectable Agora AI suppression modes. Unit tests do not validate acoustic quality.

Explicit DEBUG-only file inference check (choose `parakeet`, `whisperTurbo`, or
`whisperLarge`; `--download-model` downloads only that profile):

```bash
curl -fsSL https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/samples/jfk.wav \
  -o /tmp/astation-transcription-jfk.wav
swift build
.build/debug/astation --transcription-check \
  --local-model whisperTurbo \
  --model-root .build/transcription-validation \
  --speech-file /tmp/astation-transcription-jfk.wav --download-model
```

Real file checks passed for all three models on the development Mac and recognized the expected
"ask not what your country can do for you" speech. Paid Agora end-to-end streaming,
physical microphone/app capture together with captions, actual multi-monitor
mouse dragging, and Intel performance remain manual validation items.

To exercise two real local engines concurrently against the same downloaded
model and public fixture (no device capture or cloud calls):

```bash
ASTATION_TEST_MODEL_ROOT=.build/transcription-validation \
  ASTATION_TEST_SPEECH_FILE=/tmp/astation-transcription-jfk.wav \
  ASTATION_TEST_WHISPER=1 \
  swift test --filter LocalTranscriptionIntegrationTests
```

This opt-in test checks both transcripts, source identities, and final captions;
normal test runs skip inference unless the paths are explicitly provided. The
extra Whisper opt-in runs both profiles sequentially to limit memory use.

Transcription is a feature inside Astation, not a separate application. Build with
`swift build`; use the normal `scripts/run-dev.sh` development bundle when ready
to test interactively. Do not replace or restart a running development app without
consent. Packaging itself does not launch or restart the app.
