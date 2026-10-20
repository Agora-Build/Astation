# Channel envelope review and integration handoff

Reviewed 2026-10-20 in response to
[Atem #81 comment 6287830722](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6287830722).
The routing field names fit Astation's planned route family. This review
requests pinned transport text and fixtures before joint wire sign-off;
it does not approve the unfinished implementation or enable admission.

## Sources and current implementation

- Previously signed contract:
  [c685abab92535b167f5f2658c814f0f72541d9a1](https://github.com/Agora-Build/Atem/blob/c685abab92535b167f5f2658c814f0f72541d9a1/designs/protocol/atem-session-v1.md#r97-channel-atem-ch1),
  R9.7. PR #80 is merged at that unchanged head; fresh issue comments,
  reviews and inline comments contain no later contract pin.
- Discovered draft implementation:
  [Atem PR #89](https://github.com/Agora-Build/Atem/pull/89), inspected at
  `2d926313388b24dd3dc4a9bdb095a25b9989df34`.
  The contract Markdown and channel vectors are unchanged from c685aba.
  The proposed routing envelope is still only in the coordination comment.
- Astation's [remote_api.rs](../../relay-server/src/remote_api.rs) implements
  capabilities and a 503 fallback. There is no implemented
  `channels/{id}/frames` schema to conflict with these names.
- The existing relay identifies an Atem socket by `atem_id` and
  `connection_id`. The native direct listener decodes `AstationMessage`.
  Neither currently implements the proposed r9 channel dispatcher.

Atem reports the user's outbound-only direction: Atem connects to the relay
or Astation's existing :8080 listener; it opens no new listener. The relay
path remains usable without Mac Astation. Direct access uses the Mac while
it is available. This is routing of encrypted endpoint channels, independent
of the Mac's local agent-control API.

## Concrete response to the proposal

Keep the proposed top-level shapes:

```json
{"type":"channel","event":"open","channel":"opaque-id","transport":"relay"}
{"type":"channel","event":"frame","channel":"opaque-id","frame":{"ch":"atem-ch1","op":"rec","ct":"..."}}
{"type":"channel","event":"close","channel":"opaque-id","reason":"busy"}
```

`transport` is `relay` or `direct`, set by the routing adapter. No client IP,
claimed device identity, roles or other metadata is needed on `open`.
Routing hints never supply membership, host identity or authorization.
The signed handshake fields remain visible as specified in R9.7; application
records and the client's hello remain encrypted.

Pin these lifecycle details with the envelope and shared transport fixtures:

1. Scope lookup to the selected live Atem link and its local connection
   generation as well as `channel`. Validate the proposed 1-64 ASCII
   `[A-Za-z0-9_-]` characters. The routing handle differs from the
   cryptographic `channel_id = hex(th4[0..16])`; neither substitutes for the
   other. A stale HTTP handle or delayed callback cannot bind to a new link.
2. Queue `open` before the first frame; deliver each direction in order.
   A duplicate `open` cannot replace a live handshake, keys or attachment.
   Close releases that channel only. Repeated or unknown `close` is terminal
   and produces no answering close loop. An unknown frame may get the
   proposed bounded `unknown_channel` response; keep its bookkeeping bounded.
3. A link drop closes every channel on that link and fences their attachments.
   Reconnect starts fresh channels/handshakes and authoritative catch-up,
   without restoring leases or replaying prompts. Reordering, replay or bad
   AEAD tags close only the affected channel through the shared core.
4. Keep the one-init-per-second limit scoped to the live Atem link, with
   bounded open channels, pending handshakes and queued bytes. Overflow
   closes/refuses a channel explicitly; it cannot silently drop records or
   leave an unbounded queue. Limits and busy behavior need executable cases.
5. Demultiplex channel traffic before legacy native message dispatch or room
   broadcast. The Mac's own client uses the same r9 path; routing possession
   and a legacy paired link cannot bypass r9 admission once membership exists.
   In the binding adapter, use one `ClientConnection` per virtual channel;
   its instruction to close the transport closes that channel, not the shared
   outbound link and every other client's attachment.

## Size correction before pinning

The proposal's 1 MiB frame statement conflates plaintext and transport bytes.
R9.7 permits **1,048,576 bytes of plaintext** per record. Its 16-byte AEAD tag
and unpadded base64url produce **1,398,123 ciphertext characters**. Compact
JSON for `ch/op/ct` is 1,398,159 bytes; the proposed envelope with a 64-byte
channel handle is **1,398,279 bytes**. A 1 MiB outer limit rejects a legal
record.

Preserve the plaintext limit and separately bound the serialized inner frame,
outer envelope and queued bytes. A 2 MiB outer limit would accommodate the
current compact shape; it is a proposal for the next joint pin, not a shipped
limit. Document whether noncompact JSON is accepted within that outer cap.
Test the maximum legal record through actual relay and native adapters,
one-byte-over-limit plaintext and outer frames, and saturated queues. The
handshake/finish bounds must also be explicit; do not silently truncate
membership carriage to fit a transport limit.

## New fixture bytes inspected

Compared immutable Git trees rather than a merge-base diff: PR #80 was
squash-merged, so a history comparison incorrectly lists unchanged fixtures
as new. Verified all 18 old/new Git blob hashes for the nine changed files.
The changes align examples with the already settled contract:

- Five acquire messages add explicit `takeover:false`, retaining r8 behavior.
- Recovery-add now refuses `recovery_pending` before the existing 24-hour
  host-clock wait, then admits the new manager without another entry.
- The seen-retry scenario acknowledges initial open hints, isolating the
  intended seen retry from concurrent unacknowledged hint retries.
- Key-vector changes add explanatory notes only.
- Four negative push hints gain the existing sealed bytes so their named
  failure is reached; annotation fields move outside the strict seen object.
  Signed bodies, signatures and existing ciphertext bytes are unchanged.

No new product choice is introduced by these fixture corrections. This static
review does not run the scenarios or approve the rest of PR #89's code.
The previous 274 Python / 41 CryptoKit results apply to c685aba; they are
not presented as a fresh run against the implementation.

## Binding artifact handoff

Read the pinned
[binding/effect contract](https://github.com/Agora-Build/Atem/blob/2d926313388b24dd3dc4a9bdb095a25b9989df34/designs/protocol/atem-client-bindings.md),
Apple packaging script and CI workflow. They describe UniFFI Swift/Kotlin,
WASM, protected platform key callbacks, deferred signing and durable prepared
state. The
[binding CI run](https://github.com/Agora-Build/Atem/actions/runs/39399202806)
succeeded at exactly `2d926313388b24dd3dc4a9bdb095a25b9989df34`, including
Swift/Apple packaging and Linux Rust/Kotlin/WASM/end-to-end jobs. This is
upstream CI evidence, not local platform or real-runtime conformance.

That run exposes **zero downloadable artifacts**; the workflow performs a
package dry run without uploading it. Atem should provide its built SwiftPM
package/xcframework and WASM package with SHA-256 digests, the source pin and
production feature selection (without test/software-key/host features).
Astation consumes those artifacts; it does not build an Atem checkout.
Pin the envelope, bounds and executable multiplexing fixtures alongside them.
Then Astation can integrate its platform key/storage/network adapters and
relay using the shared core, retaining the runtime/platform admission gates.

Validation in this review: verified document/vector/fixture blob hashes,
inspected all nine fixture diffs and binding/packaging bytes, checked the
immutable CI head and empty artifact inventory, and reproduced the transport
size calculation locally. No Atem code was edited or built; no live trust,
account recovery, merge or deployment changed.
