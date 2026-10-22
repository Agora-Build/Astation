# Consuming the prebuilt r9 Apple client

The current Apple and relay shared-library pin is
`83c0776d21fa35c656eefaee25edd03cbbd203ee`. The
[host-route review](../designs/protocol/remote-agent-api-host-route-review.md)
records final delivery, source/runtime acceptance and verification of all four
packages from [binding run 39773150714](https://github.com/Agora-Build/Atem/actions/runs/39773150714).
The Apple ZIP is artifact `12422844613`; its exact archive and payload hashes
are in [the checked-in pin](../Config/atem-client-apple.json). The checker
passes 19 FFI assertions against its production static library. Its Swift
wrapper, package manifest and C header are unchanged from accepted 1493ca6.
The Rust-only host-route verifier becomes available to the relay at this pin;
the durable route lifecycle still needs implementation and acceptance.

Use the current pin with:

```sh
python3 scripts/check-atem-client-apple.py --install
swift test --package-path native-remote
cargo test --locked --manifest-path relay-server/Cargo.toml
```

## Historical integration evidence, 2026-10-21

The remaining sections record earlier implementation stages and package pins.
Current wiring and release gates are in [coordination status](github-coordination.md)
and the [remote API design](../designs/protocol/remote-agent-api.md).

The native adapter now also owns a durable signed-log publication sequence.
`RemoteMembershipPublication` requires a protected, atomic checkpoint writer;
an in-memory writer in tests is not a production store. It never sends requests
itself. The transport must bind a reply to the exact outstanding append before
calling `relayStored` or `relayConflict`. A fresh confirmation belongs to the
stored body, as requested by the shared provider. A blocked or uncertain instance
cannot be replaced with a new empty publisher: storage must be reconciled and
the saved pending bytes resumed. Initial construction requires an already
verified, durably pinned log. An unresolved conflict's refresh fence survives
reload; refreshed/frozen-log recovery remains to be implemented. This adapter
is not yet connected to the app's account setup, protected storage, native
signer or relay CAS routes, and does not enable r9 admission.

The app packet decoder now uses the shared generation reader for live
`verifyCommit` packets. It passes the validated integer into the wire model;
plain `JSONDecoder` cannot construct an incoming commit without that check.
Queued verification handlers capture route/account before dispatch. Other
ceremony changes, including the v2 transcript and signed-list output, remain
unwired. See the [current integration progress](../designs/protocol/remote-agent-api.md#pairing-integration-progress-2026-10-21).

Fresh validation of this stage passes all 41 native tests and 93 selected app
pairing/session/terminal/migration tests. The app compiles and links against the
adapter. These are focused runs; the earlier provisioned storage and FFI results
below belong to dependency head `74770d8`, not a new app launch or full UI run.

[Binding run 39568023465](https://github.com/Agora-Build/Atem/actions/runs/39568023465)
produced the Apple package. [The final-pin review](../designs/protocol/remote-agent-api-eaaadc2-review.md)
verifies all five matching packages and closes the host journal corruption/clock-rollback
findings. The shared client, bindings and fixtures are unchanged from 58fa1e9;
the earlier interactive consumer passed 19 FFI checks and 27 native adapter tests.
All 111 selected session/API/terminal tests also passed after incorporating main's
verification retry fix. The macOS app builds, and 37 identity/credential tests
pass in a provisioned test host with protected Keychain access required.
The earlier scheduled-worker manifest sandbox failure
does not apply to these fresh interactive results. Remote admission stays disabled.

Run the native consumer check from this worktree on macOS:

```sh
python3 scripts/check-atem-client-apple.py --install
swift test --package-path native-remote
```

It uses the existing `gh` sign-in to download artifact `12330892581`. An already
downloaded **GitHub artifact ZIP** can be supplied with `--archive /path/to/archive.zip`.
[The checked-in pin](../Config/atem-client-apple.json) verifies the archive,
all three payload digests, clean source commit and production features before
compiling the supplied Swift wrapper against the supplied macOS static library.
It runs the checked-in raw pairing examples through the shared strict reader,
plus extra malformed-input, minimum-generation and canonical-JSON checks.
The pairing fixture's Git blob hash is also pinned. Temporary check binaries
are removed afterwards. `--install` retains the verified package under
`build/atem-client/<revision>/AtemClient`; the app and `native-remote` SwiftPM
packages consume that exact dependency. Repeated installation verifies its
files and refuses a modified/extra source or a symlink. Dependency preparation
runs before Swift compilation in development, signing and CI/release workflows.

The checker compiles an Astation consumer without building an Atem checkout
or executing archive-supplied scripts/manifest. SwiftPM subsequently reads the
reviewed package manifest and compiles the supplied Swift wrapper against its
prebuilt xcframework. The checker exercises 19 FFI checks. The native module
adds immutable raw-JSON ceremony capture and one shared-core connection per
virtual channel, deferred owner signing with disconnect/deadline fencing,
typed operations and channel-only closure. It does not yet wire the app's
ceremony, membership persistence or direct/relay routers. Remote admission
remains disabled; full app/iOS/platform/relay conformance is still required.

`RemoteChannelWriter` prepares the outbound R9.7a path for both direct and
relay transports. It opens a channel before sending frames, assigns handles
without reuse during a link generation, and rejects stale routes. Its encoder
checks the full serialized 2 MiB bound before the transport sees a frame and
retains the original shared-core JSON bytes, including wide integers. This is
an outbound framing check, not a strict reader for untrusted inbound frames.
The shared core remains responsible for channel/cryptographic validation.

There are at most 64 active channels or unsent channel closes, with at most
16 handshakes in progress. A blocked close retains its slot and is flushed
before a new open; peer closes are never answered. The transport sink must
synchronously accept into a bounded queue or throw before acceptance, then
call `flush` when writable. On link loss, the future router must invalidate
the writer and notify each `RemoteAgentChannel`; the writer never holds a
socket or restores a lease. Inbound parsing/routing and live socket adapters
remain unwired.

Native verification includes 41 XCTest cases: generation syntax, duplicate
keys and context capture; handshake/authorization deadlines; a signature
arriving after disconnect; stale routes; operation rejection versus transport
failure; channel-only closure; and twelve outbound writer cases covering exact
envelope bounds, original frame bytes, capacity/backpressure, no handle reuse,
late routes and reentrant link loss. A public signed membership
prefix is verified by the production core, which then creates a real `init`
and rejects a malformed `accept` before requesting a signature. Fourteen new
publication cases exercise the production publisher/verifier with test-only
software signing keys: checkpoint/signature ordering, storage failures,
restarts, exact retries, conflicting relay replies, process-wide ownership,
captured host generations and a complete log over 1 MiB. None of these runs is
the upstream scenario harness.
The final package's wrapper/static library and AstationRemote module also
compile/link directly with `swiftc` for arm64 and x86_64 iOS 17 simulator
targets using the installed simulator SDK. The `xcodebuild` package invocation
was unavailable in this session (CoreSimulator/Xcode mismatch and no recognized
project/workspace/package). Neither check establishes simulator execution.

The earlier full-app CI at f9d6ac5 failed one existing verification
UI timing assertion; see [#62](https://github.com/Agora-Build/Astation/issues/62).
Its 32-test UI suite passes locally on the same verification source/test bytes.
The earlier local caption scroll failure remains separately tracked in
[#61](https://github.com/Agora-Build/Astation/issues/61). Current 8b4d3c1 macOS/relay/webapp CI is green; this dependency update does not
claim a fresh full-app test execution.

The current GitHub artifact expiry is recorded in its API metadata. A later durable artifact
handoff must update the pin after review; the checker never substitutes a
different build or downloads source as a fallback.

The relay's initial `remote_api::push_ack::encode` implementation separately
splits complete shared-core acknowledgment identities by encoded UTF-8 bytes,
including commas and the entire `type:relay` wrapper, at 262,144 bytes. Its
tests cover the public 770/771-identity boundary, mixed open/resolved/seen
identities, ordering, Unicode/escaping, the exact byte boundary and oversized
indivisible identities. It is transport preparation: the future authenticated
ingress must verify with the shared core and commit each disposition before
passing identities to this encoder. No live acknowledgment path is enabled.
