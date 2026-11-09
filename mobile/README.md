# Astation Mobile

Flutter presentation for iOS/iPadOS and Android phones, tablets and folding or
dual-screen windows. The approved design is in
[`designs/mobile-app.md`](../designs/mobile-app.md) and
[`designs/mobile-ui`](../designs/mobile-ui/mobile-ui.md).

## Current state

The foundation includes the approved welcome, Chats / Agents / Account, approval
stack and exact-rule confirmation, formatted replies, per-agent drafts,
conversation switching, approved-profile selection, activity/receipt UI and
responsive panes using actual window/display features. The mobile card has a
phone icon. No terminal is exposed on mobile.

Both native projects load the same verified Atem SDK revision used by the Mac.
iOS links `native-remote` (including its existing R9 adapter); Android links the
published Kotlin/UniFFI wrapper and JNI libraries. Native browser-opening and
development environment persistence are implemented. Native method/event
channels are reserved for validated presentation data and typed intents.
Tokens, private keys and protected checkpoints must never cross into Dart.

The native bridges implement public-client browser login using the confirmed
[Portal #30 contract](https://github.com/Agora-Build/Portal/issues/30#issuecomment-6715527724).
iOS reuses `AccountOIDCClient` and `AccountTokenProvider` from `native-remote`
with `ASWebAuthenticationSession` and device-only Keychain storage. Android uses
AppAuth's system browser, verifies ES256 tokens against same-issuer JWKS, and
encrypts refresh credentials with an AndroidKeyStore AES-GCM key. Both use
PKCE S256, state/nonce and exact registered callbacks, serialize refresh rotation,
persist a pending marker before consuming a refresh token, and fence late replies
after sign-out/environment changes. Access tokens remain in native memory.

**Real dev sign-in, code exchange, refresh rotation and authenticated Station
HTTP admission pass on both platforms as of 2026-11-08. Protected device
enrollment, live agent dispatch and APNs/FCM are not complete.** The native bridge
still refuses host actions; successful account login is not device membership.
The separate preview backend must never be substituted for production state.

The native snapshot explicitly reports `enrollmentAvailable: false` until a real
trusted-device enrollment flow is implemented. Chats and Account show **View
setup status**, which explains the limitation without calling the placeholder
native operation or asking the user to sign in again. Enrollment failures appear
inside the setup sheet, including when it opens above an Account sheet.

The follow-up [protected identity and manager-review core](../designs/protocol/mobile-device-enrollment.md)
is on `feat/mobile-device-enrollment`. Native device keys and exact signed-log
approval helpers are implemented and tested. The phone/manager ceremony,
sealed account-key handoff and independent R9 coordinator are not yet wired to
the app. These primitives do not change the setup-capability flag.

## Toolchain and dependencies

- Flutter **3.47.9**, framework revision
  `c197ca5199e9ee5661e865596c9c07294dfab51c`; Dart 3.13.7.
- iOS **17+**, Xcode with an iOS SDK. Simulator execution needs an installed
  runtime; compiling a simulator app does not imply device/runtime testing.
- Android API **24+**, JDK **21**, the Android SDK and NDK requested by Flutter.
- Atem SDK **`2b0c384e7213e5d4637cdba1f0a78ccbc53a2083`** on both platforms.
- Android native X25519/HPKE: Google Tink **1.24.0**, isolated behind the native
  key adapter and checked against the same published vector used on Apple.
- Commit `pubspec.lock`. Local IBM Plex font assets use OFL 1.1; their license
  and source hashes are in `assets/fonts`. The Vox mark is the existing official
  Vox favicon, not a replacement logo.

From the repository root, install the required immutable packages:

```sh
python3 scripts/check-atem-client-apple.py --install
python3 scripts/check-atem-client-android.py --install
```

The scripts consume GitHub build artifacts; they never edit or build an Atem
checkout. Android additionally verifies all three ABIs and 16 KiB page alignment.
They refuse an already-installed package that differs from the verified source.

## Verify and build

With Flutter on `PATH`, from `mobile/`:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tool integration_test
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --debug --no-codesign
cd android && ./gradlew :app:testDebugUnitTest :app:lintDebug
```

On this workspace Flutter is at `../.build/flutter-sdk/bin/flutter`. Use JDK 21
for the Android build. The debug APK is
`build/app/outputs/flutter-apk/app-debug.apk`; the simulator app is
`build/ios/iphonesimulator/Runner.app`. Neither is a distribution build.
Release signing, mobile provisioning and physical hardware acceptance remain.

Builds and tests verified locally on 2026-11-03:

- Android debug APK with the actual published SDK/JNA libraries.
- iOS simulator app linking the existing Swift R9 package and supplied library.
- 35 Dart unit/widget tests: account/process isolation, exact rule matching,
  takeover fencing, double-submit prevention, sign-out during a pending send,
  drafts, role/background gates, rich Markdown without remote image fetches,
  and phone/tablet/vertical/horizontal hinge layouts at normal/large text sizes.
- Seven Python SDK artifact/integrity checks.

The mobile workflow runs analysis/tests and both platform builds on pull requests
that affect these modules. PR #72's analysis, iOS, relay and web checks passed.
macOS and Android CI attempts stopped on upstream GitHub artifact HTTP 504s;
equivalent local builds/tests passed. The exact merge-time evidence and limitation
are recorded in [PR #72](https://github.com/Agora-Build/Astation/pull/72#issuecomment-6719718158).

## Review the interface

```sh
flutter run -t lib/main_preview.dart
flutter test tool/capture_previews_test.dart
```

The preview sign-in enters **sample data only**, with a persistent banner. It
does not send a prompt, launch an agent, enroll a device or open real approvals.
`lib/main.dart` imports only `NativeGateway`. Captured PNGs go to the ignored
repository `.build/mobile-preview/` directory. The HTML prototype remains useful
for design review through `atem serv files` and is separate from this runtime.

## Existing service contract

Reuse Auth's discovery/PKCE/token/refresh APIs and Portal's existing browser
account/consent flow. Use the exact selected Station as OAuth resource.
After native membership verification, use Station's existing R9 log/recovery
storage and `/api/remote/v1/channels` WebSocket, with SDK operations for registry,
chat, approvals, host profiles and receipts. Native member connections do not
borrow an integration service token or depend on the Mac being awake.

Every snapshot has bridge version `1`, a native security `context`, and a revision
that increases for the lifetime of the bridge, including environment changes.
Account/environment/identity changes retire the prior context and clear drafts
and selections. Host/process replacements use full typed targets. Native code
must revalidate the context, target, foreground state, membership, permission and
pending approval immediately before effects; Dart checks are presentation guards.
Durable request IDs, receipt recovery and lease lifecycle belong to the native
SDK adapter. The UI must never replay an uncertain command or launch.

## Dev mobile login acceptance

Auth's two public clients are live on dev. Their exact callbacks are:

| Client | Callback |
| --- | --- |
| `astation-ios` | `build.agora.astation.ios:/oauth/callback` |
| `astation-android` | `build.agora.astation.android:/oauth/callback` |

Use issuer `https://auth.dev.agora.build`, resource
`https://station-dev.agora.build`, and scopes
`openid profile offline_access astation.remote`. The Mac callback stays loopback.
Development builds select dev by default; release builds select production.
Production mobile client registration has not been verified by this work.

With an unlocked phone or booted simulator/emulator, run separately for each:

```sh
flutter test integration_test/dev_login_test.dart -d <device-id>
```

Complete the actual account login and app confirmation in the system browser.
The native test validates the callback, exchanges the code, forces one serialized
refresh, requires a new refresh token with unchanged `auth_time`, and sends the
access token to Station's authenticated membership-log endpoint. A missing log
returns the expected `404 recovery_record_not_found` after the account gate.
Only redacted result flags are printed. The test does not create a membership
log, enroll the phone, or claim that an R9 channel/agent operation succeeded.
The full member channel check remains a separate gate after native enrollment.

The `verifyLogin` method exists only in development builds and returns no tokens.
It intentionally consumes one refresh token; a lost refresh reply requires a
new sign-in rather than reusing a token Auth may already have rotated.

Android also has an account-free device regression test for the browser callback:

```sh
cd android
./gradlew -Ptarget=lib/main.dart :app:connectedDebugAndroidTest
```

It sends a synthetic callback with Chrome's `NEW_TASK | CLEAR_TOP` flags through
the real redirect activity and checks that AppAuth reuses its pending activity.
Keep the main activity's default task affinity: an empty affinity sends the
callback into another task and loses the pending login. After changing affinity,
close the old app task before testing; an existing task retains its old affinity.
The Gradle project keeps test APKs installed after connected tests so cleanup
does not erase a developer's saved sign-in. The tests remove only their own
synthetic identity records and keys. Flutter's separate live-login harness has
its own application lifecycle; use a disposable device for that acceptance run.
