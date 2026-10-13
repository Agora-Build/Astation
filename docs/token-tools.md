# Token Tools

Open **Tools > Show Projects**, select a project, and click **Generate Token...**.
You can also right-click a project or open **Tools > Token Tools...**. Token Tools
opens as a sheet in the Agora Projects window. Its project picker starts with
the chosen project; **Custom App ID...** supports another project's App ID and
App Certificate without saving either input.

## Generate

Choose RTC or RTM. RTC supports a numeric UID or a user account, publisher or
subscriber access, and custom join/audio/video/data privilege expiries. The
channel and identity must match the client joining Agora. Numeric UID 0 grants
access to any UID; use a specific identity when you need a token scoped to one
user. RTM uses a user ID. RTC can optionally include RTM login with the same or
a different identity and its own expiry.

Expiries are seconds after issuance. Token and service-privilege expiries are
independent; access ends when the applicable token or privilege expires.
The defaults are publisher access and 3,600 seconds. Every requested expiry must
be positive. Channel names are limited to 64 UTF-8 bytes, RTC accounts to 255 ASCII characters,
and RTM user IDs to 64. Invalid numeric UIDs are rejected rather than becoming
UID 0.

Click **Generate Token**, then **Copy Token** or **Inspect**. Editing inputs or
changing project clears the previous result and disables Copy so the old token
cannot be mistaken for a new one. Project credentials are resolved again when
generating; removed projects cannot use a cached certificate. No tokens or
custom certificates are persisted by this window. Closing it clears its values.

Generation runs locally. Neither the App Certificate nor token is sent to Atem
or the relay. The Atem executable does not need to be installed or running.
Certificates are never included in diagnostic messages. Production end-user
applications should obtain scoped tokens from their trusted backend rather
than receive an App Certificate.

## Inspect And Verify

Paste an AccessToken2 token and click **Decode Token** to see its App ID, issue
time, token expiry, services, identities and privilege-expiry dates. Decoding
only reads fields and does not establish authenticity.

**Verify with Project** separately verifies the signature using the selected
project's certificate and checks the token's App ID. Signature validity does
not imply a token is unexpired or authorized for a particular operation; inspect
its identity, channel and privilege expiries too. Expired tokens are identified
even when their signature is valid. Editing the token or changing project clears
the verification result. Inspection rejects inputs larger than 64 KiB.

## Shared Library And Builds

All token paths use Atem's `atem-core` / `atem-core-ffi` library through C ABI 1.
The Swift service owns each returned string and frees it with the library's
matching function. The legacy Astation C API remains as a small forwarding
bridge, preserving its malloc/free contract and empty-result error handling;
it no longer implements signing or token generation. The bridge also retains
the legacy role default: subscriber for role 2, publisher for other values.

Until Atem publishes its macOS release artifacts, builds use the merged source
commit pinned in `Config/atem-core.json`. The archive SHA-256 is checked before
extracting only the two library crates. `scripts/setup-atem-core.py` creates a
consumer workspace with dependencies pinned in `Config/atem-core.Cargo.lock`;
it does not install, build or modify the Atem CLI. Test-only dependencies are
excluded, and system zlib is enabled to preserve the existing C++ builder's
serialized output. CMake builds the Rust static library and copies it alongside
`libastation_core.a`. Swift links both; the Rust library is not embedded as a
separate runtime framework. Startup and library calls check the ABI version.

Swift 6.2+ package traits disable FluidAudio's unused NeMo text-normalization
engine, whose prebuilt Rust runtime otherwise conflicts with Atem core in clean
builds. Astation uses FluidAudio's streaming ASR without this engine. The package
retains Swift 5 language mode while requiring tools 6.2+ for trait selection.

Install current stable Rust with Cargo, then use the normal CMake and Swift
build commands or `scripts/run-dev.sh --build-only`. The source pin, header,
dependency lock and interoperability fixtures must be updated together when
upgrading the library. Do not silently use whichever Atem is on PATH.

Eight regression fixtures were captured from Astation's original C++ builder
before replacement: publisher, subscriber, UID 0, maximum UID, ConvoAI, caption
publisher/bot and RTM. Rebuilding each with the decoded issuance time and salt
must match the original token byte for byte, and signature verification must
pass. Independent wire decoding, invalid-input tests and UI tests also run in CI.

The shared library is portable. Astation's existing C++ API remains available
to future Linux and Windows hosts, while its new Swift UI is macOS-specific.
Full Astation applications on Linux and Windows remain separate work.
