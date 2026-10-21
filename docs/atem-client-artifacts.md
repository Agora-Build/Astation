# Consuming the prebuilt r9 Apple client

The accepted client pin is `edeb8f0fab71d4573e41c4ca7935aab207200caf`.
[Binding run 39465726081](https://github.com/Agora-Build/Atem/actions/runs/39465726081)
produced the Apple package. [The source/package review](../designs/protocol/remote-agent-api-channel-envelope-review.md)
records its scope; it is separate from the final host/quarantine review.

Run the native consumer check from this worktree on macOS:

```sh
python3 scripts/check-atem-client-apple.py
```

It uses the existing `gh` sign-in to download artifact `12284764754`. An already
downloaded **GitHub artifact ZIP** can be supplied with `--archive /path/to/archive.zip`.
[The checked-in pin](../Config/atem-client-apple.json) verifies the archive,
all three payload digests, clean source commit and production features before
compiling the supplied Swift wrapper against the supplied macOS static library.
It runs the checked-in raw pairing examples through the shared strict reader,
plus extra malformed-input, minimum-generation and canonical-JSON checks.
The pairing fixture's Git blob hash is also pinned. Temporary binaries and
extracted packages are removed afterwards.

This builds an Astation consumer, without building an Atem checkout or executing
the package manifest or archive scripts. It exercises 19 checks against the
production FFI. It does not establish full app/SwiftPM/iOS integration, an
immutable live ceremony, membership persistence, router adapters, or enabled
remote admission. Those remain the next native integration steps.

The current GitHub artifact expires on 2027-01-18. A later durable artifact
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
