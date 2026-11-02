# Harness transport adapter requirements

## Current evidence at ade944f

The [Task 9b review](remote-agent-api-task9b-review.md) checks the concrete
supplementary two-host test and built Android/Linux harness artifacts.
The latter remains a fixed-flow fake-router package with no external-mode
adapter hook. Its sample transcript parses; it was not executed on this Mac.
The original interface response below is historical; only its later exact
bridge schema remains unpinned. The final rebased packages and full Astation
adapter/platform/relay tests still need review.


Coordination: [Astation response](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6304486807).

Status: proposed test adapter boundary, 2026-10-20. No new production wire or
public endpoint is agreed. Task 9b's promised test/artifact bytes await review.

Reply to [6304403073](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6304403073): the fixed-flow, non-production Task 9b artifact is useful with its fake-routing limits documented. The two-host test and matching production/Android packages remain pending review at your final pin.

For a subsequent **Astation transport adapter hook**, please expose these two boundaries:

- **Host side:** the packaged runtime dials a configurable Astation WebSocket URL, as `ASTATION_WS` already allows. It remains outbound-only. The relay or native :8080 adapter owns that socket; the driver must not also replace it with `FakeAstation`. A Linux container must be able to reach the configured Mac/relay address.
- **Client side:** keep shared-core handshakes, independent test keys and assertions in the prebuilt driver, but let an Astation-supplied bridge implement open/send/receive/close per logical client and target host, plus link-loss notification. An executable bridge using stdin/stdout NDJSON is suitable; this is test-process I/O, not a new production wire format. Pass each inner `atem-ch1` frame as its original JSON bytes/text; the adapter supplies the actual client ingress and wraps/unwraps R9.7a on the host link. The public client ingress is still unimplemented, so please avoid hard-coding a new HTTP/WS path or credentials API into the driver.

The adapter assigns handles, sets `direct`/`relay`, and scopes routes to the current host connection generation. It must preserve per-channel order, open-before-frame and channel-only close; link loss ends all affected channels and requires new handshakes, without lease restoration or prompt replay. Keep the pinned 2 MiB serialized envelope bound and separate 256 KiB `type:relay` bound. A channel close never closes the shared host socket.

For setup, ship a disposable fixture manifest with account/genesis/head, both hosts' IDs/keys/trust generations, signed membership, client labels/roles/scopes and reproducible test-key references. Existing test bootstrap belongs only in isolated profiles; no live account pairing, enrollment, recovery or credential extraction. Document any test transport auth and how the adapter supplies it locally. Signed push hints/seen must reach the **real relay ingress**, with `push_ack` returned after durable handling; the external mode must not silently acknowledge them in the fake router.

Useful test controls are disconnect/reconnect one client, drop/reconnect one host link, hold/release adapter I/O, and delayed/lost push acknowledgment. Record outcomes/transcripts so we can distinguish adapter-induced stalls from your still-engine-only runtime link-writer stall. The exact bridge schema can be pinned with that later artifact; this reply agrees no new r9 fields or public endpoint.

Fresh check: PR #89 is still `56c4489bde35e83460655f686e2eff8305b09010`; its tree is identical to the reviewed Task 9a tree. [Test 39516486123](https://github.com/Agora-Build/Atem/actions/runs/39516486123) has now completed successfully, joining core/bindings. No new implementation bytes or Task 9b packages are approved here. No user product/security decision is pending.

Generated with SMT <smt@agora.build>
