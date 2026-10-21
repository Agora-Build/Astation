# Consuming the prebuilt r9 Apple client

The current client pin is `58fa1e92bb99fed1ce81a42fb63ac1226782705b`.
[Binding run 39538413559](https://github.com/Agora-Build/Atem/actions/runs/39538413559)
produced the Apple package. [The final-pin review](../designs/protocol/remote-agent-api-final-pin-review.md)
verifies all five matching packages and the client delta from accepted edeb8f0.
Client consumption is independent of the remaining host quarantine finding;
remote admission stays disabled.

Run the native consumer check from this worktree on macOS:

```sh
python3 scripts/check-atem-client-apple.py --install
swift test --package-path native-remote
```

It uses the existing `gh` sign-in to download artifact `12317503957`. An already
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

Native verification includes 15 XCTest cases: generation syntax, duplicate
keys and context capture; handshake/authorization deadlines; a signature
arriving after disconnect; stale routes; operation rejection versus transport
failure; and closure affecting only its own channel. A public signed membership
prefix is verified by the production core, which then creates a real `init`
and rejects a malformed `accept` before requesting a signature. The 14 lifecycle
and capture cases are adapter tests, not the upstream scenario harness.
The final package's wrapper/static library and AstationRemote module also
compile/link directly with `swiftc` for arm64 and x86_64 iOS 17 simulator
targets using the installed simulator SDK. The `xcodebuild` package invocation
was unavailable in this session (CoreSimulator/Xcode mismatch and no recognized
project/workspace/package). Neither check establishes simulator execution.

The current GitHub artifact expires on 2027-01-19. A later durable artifact
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
