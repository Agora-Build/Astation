# Screen sharing

Astation captures macOS displays and selected regions with ScreenCaptureKit and
publishes custom video and audio tracks through Agora RTC. macOS 14 or later is
required. The browser session page receives the screen and audio with the Agora
Web SDK.

Native and browser clients use Agora's live profile with host roles so they can
publish and receive media in the same channel.

## Mac controls

Join an Agora channel, then choose **Start Screen Share** from the menu bar.
Choose a display, optionally select **Share region only**, and choose a frame
rate. **Include system audio** shares audio from other apps; it is off by
default. The audio and frame-rate choices are remembered for hotkey and console
starts. Microphone mute is independent of system audio.

Capture uses the display mode's native pixel dimensions, including Retina and
scaled display modes. Region coordinates are converted from pixels to
ScreenCaptureKit points. NV12 and H.264 require even dimensions, so an odd region
is trimmed by at most one pixel at the right or bottom edge.

The default target is 60 fps, with 30 fps available. ScreenCaptureKit may emit
fewer frames for an unchanged screen. Agora uses H.264 with a hardware encoder
preference and a bitrate target of 4-50 Mbps based on pixel count and frame
rate. Resolution is prioritized when bandwidth is limited, so actual frame rate
may fall. Native resolution is a capture and encoder target; RTC compression is
lossy, and hardware, network, and browser limits affect the received quality.
There is no automatic fallback that downsizes the capture to 1080p.

The bridge sends raw NV12 to Agora's C++ API. It reads contiguous planes directly;
buffers with separate plane storage or differing row strides are repacked into
a reusable buffer without scaling. System audio is captured as 48 kHz stereo,
converted to 16-bit PCM, and sent in 10 ms packets through a mixable custom track.
Audio and video timestamps use the same monotonic clock. Astation's own windows
and audio are excluded from capture.

Stopping, leaving the channel, or replacing the engine disables and drains
capture callbacks before releasing the engine. ScreenCaptureKit stop errors
clear the sharing state. The native client renews expiring RTC tokens using the
active channel's project.

## Browser controls

Create a share link from the Mac and open it in a browser. Video is shown with
its aspect ratio preserved and the high stream requested. **1:1 size** displays
one received pixel per display pixel, accounting for Retina scaling, with
scrolling; **Fit to window** returns to the normal view. This does not change the
transmitted resolution. If the browser blocks audio autoplay, **Play shared
audio** resumes it from a user gesture.

The browser can also publish a screen using **Share screen**. **Include audio**
requests system or tab audio from the browser picker. Support depends on the
browser and selected source; Chrome/Edge tab sharing is the most reliable way
to share tab audio on macOS. The page reports when the browser returns no audio
track. Microphone capture remains a separate control.

Browser screen sharing uses a second Agora client and a separately allocated
UID with the session's existing wildcard token. The screen identity is reused
on subsequent starts, avoiding repeated participant allocations. It consumes
one additional session slot. Browser tracks are stopped and closed on explicit
stop, picker cancellation, join/publish failure, or the browser's Stop button.

Share links currently carry a fixed token valid for one hour. The browser warns
before expiry and disconnects when it expires; ask the host for a new link to
continue. Native token renewal does not update an already created web link.

## Verification

Build and run the app from the worktree with `./scripts/run-dev.sh --build-only`
and `./scripts/run-dev.sh`. The script creates a signed development app and
launches it through LaunchServices so macOS attributes permission to Astation.
Ensure **Screen Recording** (or **Screen & System Audio Recording**) is enabled
for Astation in macOS Privacy & Security settings. Avoid launching the bare
`.build/debug/astation` executable: macOS may attribute that request to the
terminal app instead.

If no system permission prompt appears, choose **Open System Settings** in
Astation's permission alert. macOS may suppress repeat prompts after a denial.
Enable Astation in that pane, then quit and reopen the development app.

1. Join an Agora project/channel and create a share link.
2. Share a Retina display at 60 fps, open the link, and inspect motion and small
   text. Test 1:1 and fit views on desktop and mobile.
3. With the microphone muted, play audio in another app. Test system audio on
   and off; check that incoming call audio is not fed back.
4. Share a region, stop with the menu/hotkey, restart, then leave the channel.
5. From Chrome/Edge, share a tab with and without its audio and use the browser
   Stop button. Check that the source and audio capture are released.

Automated checks:

```sh
ctest --test-dir build --output-on-failure
swift test --filter ScreenShareCaptureTests
node webapp/tests/codec.test.js
node webapp/tests/nginx.test.js
node --test webapp/tests/screen-share.test.js
cargo test --manifest-path relay-server/Cargo.toml rtc_session
```

An optional test publishes the primary display and system audio to a temporary
Agora channel for 20 seconds using the existing Astation sign-in. It skips when
the test runner lacks Screen Recording permission or the sign-in needs refresh:

```sh
ASTATION_SCREEN_SHARE_LIVE_TEST=1 swift test --filter ScreenShareLiveValidationTests
```

The live test reports frames accepted by Agora and checks that native dimensions
were preserved. It does not certify the browser's decoded resolution or a
sustained 60 fps rate; those require a receiving client and moving screen content.
