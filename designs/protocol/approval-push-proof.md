# Authenticated host push: joint proof draft

Status: Astation proposal for Atem review, updated 2026-10-19. Not enabled
ingress and not a replacement for atem-session r8. Pin to an agreed revision
with shared signature fixtures before either side sends these fields.

Product policy: connected clients receive approval cards/events immediately.
If still pending and unexpired, initial OS push is due at 60 seconds from
creation and a reminder at 180 seconds. Desktop defaults to receiving both;
mobile defaults to the reminder only. No desktop/mobile identity category is
needed; a recipient notification preference selects its first stage. Desktop
availability does not control either timer. See the
[remote API design](remote-agent-api.md).

## Identity and authority

A routing room, claimed atem_device_id, SSO token and storage account are not
host identity. A manager-authorized host record must bind account id, pinned
genesis hash, Atem device id, host trust generation, signing algorithm and
public key. Its signature chains to the same verified membership root as the
recipient devices. Publish exact host-record bytes in the membership contract.
The relay cannot enroll itself or replace that root using an account login.

Current compatibility pairing has no relay-verifiable manager-signed host
record. Until the joint membership/freshness gate is satisfied, host push
ingress remains refused. Existing native device-token registration and provider
adapters do not supply this missing proof.

## Connection challenge

1. Relay issues 32 cryptographically random nonce bytes plus a random challenge
   id on the host's current socket. Associate it server-side with that exact
   socket generation, deployment audience and a monotonic deadline <=60 s.
   It is single-use; failed proof, reconnect or timeout invalidates it.
2. Host signs a domain-separated canonical statement containing protocol
   version, audience, challenge id, nonce, relay connection generation,
   account id, genesis hash, atem_device_id, host_trust_gen, host-record hash,
   membership seq and membership head hash. Issued/expiry wall times are
   bounded hints and cannot extend the monotonic challenge deadline.
3. Relay verifies the complete membership chain, current host record, proof
   signature and freshness against the stored high-water mark. Consume the
   challenge atomically. Capture an immutable authenticated host context:
   account/root, device/key/trust generation, socket generation and validated
   membership head. No later handler may resolve identity from mutable routing
   fields. A relay restart requires a new challenge/proof.

Proposed encoding: RFC 8785 JSON over the protocol's integer-only safe-number
subset, UTF-8 without BOM, no duplicate/unknown keys; explicit algorithm ids;
base64url without padding for bytes; SHA-256 lowercase hex for hashes. Prefix
signature inputs with `agora.build/host-push/v1` plus a NUL byte. Use the host's
existing verified signing algorithm, with explicit raw signature encoding.
Cross-language vectors must settle the exact choices before implementation.

## Event acceptance and dispatch

Each event has a random event_id and kind push_approval or push_resolved. Bind
its signature to the authenticated account/root, host key/trust generation,
approval id, session and process generations, payload digest, issued_at and
expires_at. An open must also bind an immutable approval-creation timestamp;
this is distinct from a retry's event issue time and cannot be reset by a new
event id. The exact field, units, clock-skew validation and open/resolution
ordering must be agreed with Atem and covered by signature vectors before
implementation. Sign with a distinct event domain (`agora.build/approval-push/v1`)
so a connection proof cannot be replayed as an event. A durable event signature
lets either relay replica verify provenance after socket loss. Do not require
the host process to stay online after durable acceptance.

- Check admission in order: wire limits/canonical encoding, current connection
  identity, host binding, signature, trust/freshness, exact event digest and
  timing. Body fields cannot widen the captured context.
- Commit event, approval lifecycle and outbox jobs transactionally before
  returning accepted. Same event id and digest returns the original receipt;
  changed bytes get conflict. Bound dedup retention to the retry contract.
- Key the approval lifecycle by account/root, host key/trust generation,
  session/process and approval id. A resolution tombstone wins over an earlier
  or delayed open, even if it arrives first or through the other replica.
- Only currently enrolled recipients with control (plus the protocol's required
  view permission) and fresh authority qualify. At send time recheck host and
  recipient revocation, key/generation, token generation, expiry and resolution.
  Never fan out by SSO/data-account membership alone.
- Persist retry/backoff/claim state across replicas. An interrupted provider
  send may be retried; APNs collapse-id and FCM tag are approval_id. Provider
  delivery is at-least-once/best-effort, not exactly-once. Unknown send outcomes
  never authorize an answer. Conditionally invalidate only the failed token
  generation; do not delete a concurrently rotated address.
- Bound and redact tool/summary text. Do not include raw arguments, transcripts
  or credentials. Push hints and provider receipts cannot create actionable
  cards. Tap reconnects and fetches authoritative r8 approval state. The current
  answer remains lease-free and subject to current control permission.

## Recipient notification preferences

Do not add a desktop/mobile identity category just for push scheduling. Each
client registers a first-alert-stage preference with its delivery address:
desktop defaults to stage 1 and mobile to stage 2. These are presentation
preferences, not permissions or principal types. Validate the bounded allowed
values and bind updates to the authenticated enrolled device and token
generation. Body fields cannot retarget a token to another device or account,
and changing a preference cannot enroll a device or grant control. Current
registration only records provider/token; agree this small preference and
stage-marker extension before implementing it.

Before OS submission the relay filters stage 1 using that preference; stage 2
is sent to all otherwise eligible recipients, including desktops. Native
clients can filter stage metadata as well when running. Client-only filtering
cannot reliably suppress an alert rendered by the OS while mobile is
suspended or terminated. Silent/data push and notification extensions cannot
be the sole mechanism for enforcing the mobile delay. APNs/FCM alone does
not distinguish desktop/mobile, and no hardware classification is required.

Mac OS delivery uses its provisioned APNs registration; iOS/Android use their
verified platform adapters. Windows/Linux desktop delivery requires a
separately implemented and verified adapter; desktop PC support is a product
target, not an implemented provider path. A connected desktop can still show
the authoritative in-app approval without an OS push token. OS/provider
delivery remains best effort, especially while a machine is powered off.

Persist the preference and delivery attempts/completion per full approval
identity, recipient, token generation and stage. Recheck the current
preference before a provider attempt and handle updates/token rotation without
resetting the approval deadlines. A successful initial send must not suppress
the reminder to that same desktop. A failed stage-1 send or missing recipient
must not block stage 2. All stages share the same authoritative approval
lifecycle; answering anywhere cancels remaining
stages and clears existing notices where supported.

Keep live-card/in-app-banner dedup separate from per-stage OS delivery. An
already visible card is not evidence that a scheduled stage was delivered or
handled. Existing native approval-only alert tracking needs this distinction
before staged notifications are enabled; stage retries should update the
same approval notice instead of producing extra cards.

## Durable desktop-first escalation

- Atem sends the signed open promptly when the approval is created, not after
  waiting for a Mac response. It sends a signed resolution when any device or
  the local terminal answers, or the request otherwise closes. Automatic
  resolution, denial, cancellation and expiry also close the escalation.
- Transactionally persist the validated original creation time, approval
  expiry, resolution tombstone and both stage deadlines before acknowledging
  the open: creation plus 60 seconds for stage 1, plus 180 seconds for stage 2.
  Redelivery, new event ids, catch-up and reconnect cannot postpone or
  duplicate either stage. Validate time bounds; malformed or inconsistent
  timestamps cannot bypass scheduling/admission. Agree clock handling in
  fixtures. Atem emits one open promptly; it does not run either push timer.
- The relay scheduler runs independently of desktop sockets, wake state and UI.
  Seeing the request, receiving an alert or holding a lease is not a response.
  Stage 1 remains due at 60 seconds while desktop is offline; stage 2 is
  independently due at 180 seconds even without a stage-1 token/successful send.
  Another authorized client's answer cancels both stages just as a Mac answer
  does. A provider delivery acknowledgment alone cannot cancel the reminder.
- No stage is sent before its own due time, or when now >= approval expiry.
  If expiry <= a stage deadline, omit that stage without changing the agent's
  deadline. A late accepted open/worker recovery handles only the currently
  due stage while valid, unresolved and authorized; once stage 2 is due, skip
  overdue stage-1 work instead of replaying both alerts together. Resolution
  tombstones suppress delayed opens even when resolution arrived first.
- At each attempt, transactionally claim the job and recheck current lifecycle,
  host/recipient authority and token generation. Persist claims, attempts and
  completion across replicas/restarts. A successful stage is not a periodic
  reminder; retry unknown/provider failures with the same identity, recipient,
  stage and expiry under the bounded retry contract. Stop stage-1 retries once
  stage 2 is due; first delivery cannot postpone or suppress the reminder.
- Recheck resolution immediately before provider submission. A resolution
  after that boundary cannot reliably retract the external send. Cancel
  remaining attempts and use push_resolved to coalesce/clear notices where
  supported. A late tap always asks Atem for current state before any action;
  resolved/expired requests cannot become actionable from push metadata.

The authenticated ingress and durable scheduler remain gated on the joint
membership/freshness and signed event contract. Provider adapters alone do
not implement this policy, and a headless test cannot prove background OS
delivery. Use APNs/FCM for offline escalation regardless of whether foreground
traffic uses WSS or a future Agora Signaling adapter.

Do not dispatch after a known removal. An external provider already holding a
notification cannot retract disclosure, and offline revocation freshness needs
the construction agreed in [the trust review](account-trust-review.md).

## Shared acceptance tests

Wrong host/key/root/account, wrong audience/socket/challenge, reused/expired
proof (including now == deadline), altered event bytes, replay across replicas,
trust change between admission and commit, disconnect after commit, repeated
open/resolution, resolution-before-open, delayed worker, host/member revocation,
token rotation during an invalid-token reply, provider retry/restart, and
forged push metadata on the native client. Provider fakes inspect signed HTTP
requests; separately verify real APNs/FCM credentials and delivery.

Use a controllable clock for 59.999 s / 60 s and 179.999 s / 180 s dispatch;
stage-2 preference causes no stage-1 OS submission even with mobile killed;
stage-1 preference can alert at both stages without retry duplicates. Cover
expiry before/at/after each stage, answer before/between/after stages, desktop
online-but-unanswered/offline/without token/provider failure, same-provider
tokens with distinct notification preferences, invalid/updated preferences,
token rotation and restart, late opens/workers after either deadline, no
replay of stage 1 after stage 2 is due, answer on another device or local
terminal, resolution-before-open, duplicate opens with new event ids,
creation-time tamper, resolution before claim/before send/after provider
acceptance, and a late tap. Viewing/provider acknowledgment cannot cancel or
reset either timer. Separately verify suspended/terminated mobile behavior
with real provider delivery; headless/client-filter tests alone do not prove it.
