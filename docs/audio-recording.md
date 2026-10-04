# Local audio recording

## Sources and original tracks

Use Settings > Audio & Recording. Enable a microphone and optionally choose
selected applications or all system audio. The latter two modes are mutually
exclusive. System capture excludes Astation's own playback. Applications are
saved by bundle identity; the catalog groups known
helper processes by process ancestry and refreshes memberships during capture.
Shared XPC services that macOS does not attribute to an app may not be selectable
as part of that app on every OS version. Verify your actual application's audio
with preview, especially browsers and conferencing apps.

Core Audio process taps require macOS 14.2+. Microphone capture uses
AVAudioEngine and supports macOS 14. Capture is independent of RTC, credentials,
and the relay. Recording and preview alone never upload audio. Optional Agora
cloud transcription uploads only its checked sources after explicit consent.

Live Transcription has a separate Settings sidebar item and independent Start/Stop
controls. It can run without recording, alongside recording, or on a subset of
the enabled sources. Stop Recording closes original files but keeps capture and
captions live; Stop Transcription leaves an active recording running. See the
[transcription guide](live-transcription.md) for combinations and source labels.

The recorder saves Float PCM CAF/WAV at each capture source's sample rate and
channel count. It does not use the existing 16 kHz speech-recognition callback.
"Original" means samples supplied by macOS before Astation processing, not an
original compressed file or a guarantee of bypassing hardware/app processing.

Microphone capture is shared by device with local dictation and RTC through
independent leases/queues. RTC mute or channel leave does not mute local recording,
restart its microphone, or change its original PCM. RTC has a separate processed
branch; dictation polishing only edits text. See the
[dictation/RTC guide](live-transcription.md#voice-dictation-and-optional-llm-polishing).

Independent tracks share a host-time origin. Late starts and substantial capture
gaps receive silence padding with frame ranges recorded in `session.json`.
Clock jitter is tolerated; original samples are not discarded to force clocks
to agree. Mixed exports with resampling/drift correction are a later milestone.

The default recording folder is `~/Documents/Astation/Recordings`, resolved for
the current macOS user; choose a different folder in settings if needed. On the
first launch of the updated app, a saved old default of `~/Music/Astation Recordings`
migrates to the new default. Custom folders and later explicit choices of the old
path are retained. Existing recordings are not moved. The folder is created when
recording starts.
Every recording gets its own directory. Files split at the configured time or
1 GB, whichever comes first. A failure retains completed audio and writes a
failure manifest where the disk remains writable. A crash may leave a manifest
marked `recording` or `paused`; automatic recovery is not implemented.

## Preview and permissions

Preview must be started explicitly. It never creates files or plays audio
through speakers. Hiding the page stops preview unless recording or live
transcription is active.
Waveforms show the last five seconds on a fixed scale, with separate stereo
lanes. RMS/peak values are dBFS; clipping is held briefly. Zero samples are shown
as silence; no recent samples are shown as waiting for audio.
Meter readings retain the last real measurement between audio callbacks, rather
than treating empty worker polls as silence. They expire after one second without
samples; actual silent buffers update the levels immediately. The sound status
has a 400 ms release hold and separate detection/release thresholds to avoid
label chatter near the noise floor. These display rules do not alter saved audio.

Allow Astation's Microphone and Screen & System Audio Recording permissions as
requested by macOS. Launch the development build using `scripts/run-dev.sh`,
which creates and opens `.build/Astation Dev.app`. Launching a bare executable
from a terminal can make macOS attribute audio-capture permission to the terminal
instead; some terminals lack the required usage description and capture returns
silence even when the API succeeds. The development and release bundles both
include microphone and system-audio usage descriptions.

Source/file settings are locked during recording. Pause retains capture for
meters while omitting the paused interval from files. Input-format changes,
microphone disconnection, sleep, queue overflow, and write failures stop recording
and report the cause. App closure clears its process membership; reopening the
app can resume its track. A changed output format requires a new session.

Output process taps start before the microphone to avoid reconfiguring its
engine while creating a private capture device. Engine notifications alone do
not mean the input format changed: when rate, channels, and sample layout are
unchanged, Astation restarts a stopped microphone engine and keeps the other
tracks and recording session. Recovery is limited to three attempts per five
seconds, including attempts across replacement devices. During preview, a true
input-format change reconnects only the microphone, with a fresh native format
and queue, while other sources and transcription remain running. Source changes
and Start Recording are locked during that reconnect; Stop Preview is available.
During recording/paused, a true format change still stops capture to preserve
original files. Aggregate inputs support discrete native layouts, including the
three-channel BlackHole + mono-microphone combination.

## Automated validation

```bash
swift test --filter 'AudioRecording|KeyboardShortcut'
swift test
```

Tests exercise native file round trips, stereo/sample-rate preservation, time
alignment, gaps, pause exclusion, splitting, file errors, queue bounds and
overflow, calibrated waveform levels, no-file preview, permission cancellation,
recorder lifecycle, microphone reconfiguration recovery, original-file retention
after a format change, saved folder choices, and shortcut migration/conflicts.
Settings layout checks include two source cards, resizing, source toggling, and
wrapped error text. Tests do not request capture permission or collect microphone
audio.

An explicit DEBUG-only native probe plays two quiet generated tones in separate
`afplay` processes, captures only one process, and checks its saved audio for the
selected 440 Hz tone and absence of the other 990 Hz tone. It preserves its
generated inputs and recording artifacts in a unique temporary directory. It
does not start the relay, use account credentials, or capture the microphone.

```bash
swift build
bash scripts/package-dev-app.sh
open -n -W --stdout /tmp/astation-audio-native-probe.log \
  --stderr /tmp/astation-audio-native-probe.stderr \
  '.build/Astation Dev.app' --args --audio-capture-check
```

Approve system-audio access when macOS asks. Core Audio setup can wait for that
decision; once setup returns, the probe waits up to 20 seconds for sound.
Read `/tmp/astation-audio-native-probe.log`: successful validation ends
with `PASS`. `open` exiting successfully only means the application launched,
not that the probe passed.

For optional light/dark UI snapshots:

```bash
ASTATION_AUDIO_UI_SNAPSHOT=/tmp/astation-recording-settings \
  swift test --filter AudioRecordingSettingsTests
```

### Implementation validation status

On the development Mac, the full Swift suite passes. Debug and
release builds pass, and the development bundle passes deep/strict signature
verification. Light and dark settings snapshots have been visually checked.
Capture setup/cancellation, delayed pause/start buffers, and sleep during setup
have regression coverage. Native process isolation is not yet verified: the
probe's macOS audio-capture permission request remained unresolved. Physical
microphone capture, real Aggregate Device recovery, browser helper attribution,
simultaneous RTC/PTT, and extended hardware recordings still need the checks below.

## Practical Mac checklist

- Preview a physical mic: speech produces a waveform, silence is flat, and no
  files appear. Check RMS/peak and clipping with a known input level.
- Preview Aggregate Device together with All System Audio. Confirm startup
  does not produce a false format-change error and both cards show activity.
- Play different sounds in two apps. Select one app and confirm only that app
  reaches its track. For browsers, test multiple tabs and helper processes.
- Record microphone plus an app; play each original independently and check
  start alignment. Pause, make sound, resume, and confirm paused audio is absent.
- Close/reopen a selected app, unplug the selected mic, switch default input,
  change the output format, and sleep/wake. Confirm status/errors match reality.
- Check recording alongside an RTC call and PTT, including mute behavior.
- Record an extended session and inspect file boundaries, disk usage, gaps, and
  the final manifest. Hardware clock drift has not been eliminated by resampling.
- Deny capture permission and use an unwritable output folder; confirm clear
  feedback and that original files are retained where possible.

## Next milestones

Basic filters and evaluation of existing speech noise-removal models come next.
Processed audio will be a separate branch from originals. After that, validate
BlackHole output, build an Astation HAL virtual microphone, and provide a native
OBS filter backed by the same processing library.
