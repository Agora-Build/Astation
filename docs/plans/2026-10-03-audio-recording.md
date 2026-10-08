# Local audio recording and processing

## Agreed scope

- Capture microphone, all system output, or the output of selected applications.
- Microphone capture can accompany either output mode. System and selected-app
  modes are mutually exclusive to avoid duplicate audio.
- Preserve separate original tracks. Recording is local and does not require
  an Agora account, RTC channel, SoX, or a virtual audio device.
- Show a real live waveform and level meter for each selected source before
  recording. Distinguish silence from unavailable capture.
- Keep the native settings sidebar and support light and dark appearances.
- The future OBS integration is an Astation filter inside OBS, not hosting OBS
  plugins inside Astation.

## Milestones

1. Native recorder, source discovery, explicit preview, live waveforms, CAF/WAV
   originals, pause/resume, session metadata, recording shortcuts and controls.
   Use Core Audio process taps on macOS 14.2+ and microphone capture on macOS 14.
   Keep the application's macOS 14 minimum; gate app/system capture on 14.2.
2. Host-independent processing library with basic filters and optional speech
   noise removal. Compare existing models on speech with overlapping keyboard
   taps and honks; preserve the original alongside processed output.
3. Validate live processing into BlackHole, then implement an Astation Core Audio
   HAL virtual microphone. AI inference stays outside device callbacks.
4. Native OBS filter adapter using the same processing library.

## Recorder implementation

- Audio callbacks only copy into a bounded single-producer/single-consumer C
  queue. Metering, file writes, and UI work happen away from the audio callback.
- Save application selections by bundle identity. Resolve helper processes by
  ancestry, and refresh process membership while capture is active.
- Do not mute tapped apps. Exclude Astation from full-system capture.
- Use a shared host-time origin to align independent tracks at their native
  sample rates. Record gaps and dropped samples explicitly in session metadata.
- Float PCM originals remain unfiltered. CAF is the default; WAV is available.
  Split long tracks to keep WAV files below their size limit.
- Preview is visual only: it does not save files, stream audio, or play through
  speakers. Stop preview when the recording page is hidden unless recording.
- Source controls are locked during recording. Pause retains capture and meters
  while excluding the paused interval from recorded time.
- Waveforms use a consistent scale, independent stereo lanes, RMS/peak dBFS,
  and clipping indication. Silence never produces invented motion.

## Validation

- Queue bounds, planar/interleaved PCM, overflow, timing, waveform amplitudes,
  peak/RMS values, and silence behavior.
- Read recorded files back to check samples, channels, native sample rates,
  alignment, pause behavior, splitting, metadata, and failures.
- Existing shortcut bindings migrate without losing voice/video settings;
  recording shortcuts participate in the same conflict checks.
- Practical Mac checks: mic and two-app isolation, application helper processes,
  app restart, recording alongside RTC/PTT, source disconnection, permission
  denial, sleep/wake, and extended recordings.

## Later decisions

ScreenCaptureKit fallback for macOS 14.0-14.1, mixed/compressed exports, audio
processing model, virtual-device distribution, and OBS packaging are follow-ups.
They are not prerequisites for the first recorder.
