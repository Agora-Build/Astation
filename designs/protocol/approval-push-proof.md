# Authenticated host push: joint proof draft

Status: Astation proposal for Atem review, updated 2026-10-19. Not enabled
ingress and not a replacement for atem-session r8. Pin to an agreed revision
with shared signature fixtures before either side sends these fields.

Product policy: connected clients receive approvals immediately; offline OS
push escalates only if still pending after 120 seconds. Mac availability does
not control the timer. See the [remote API design](remote-agent-api.md).

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

## Durable two-minute escalation

- Atem sends the signed open promptly when the approval is created, not after
  waiting for a Mac response. It sends a signed resolution when any device or
  the local terminal answers, or the request otherwise closes. Automatic
  resolution, denial, cancellation and expiry also close the escalation.
- Transactionally persist the validated original creation time, approval
  expiry, resolution tombstone and outbox due time before acknowledging the
  open. Due time is original creation time plus 120 seconds. Redelivery, new
  event ids, catch-up and reconnect cannot postpone or duplicate that job.
  Validate time bounds; malformed or inconsistent timestamps cannot bypass
  the scheduling/admission rules. Agree the exact clock handling in fixtures.
- The relay scheduler runs independently of Mac sockets, wake state and UI.
  Seeing the request, receiving an alert or holding a lease is not a response.
  Escalate after the same 120 seconds even if Mac Astation is already offline;
  another authorized client's answer cancels just as a Mac answer does.
- No approval alert is sent before due time, or when now >= approval expiry.
  If expiry <= due time, omit the approval push; do not alter the agent's
  deadline. A late accepted open can dispatch immediately after its original
  due time only while still valid, unresolved and authorized. Resolution
  tombstones suppress delayed opens even when resolution arrived first.
- At each attempt, transactionally claim the job and recheck current lifecycle,
  host/recipient authority and token generation. Persist claims, attempts and
  completion across replicas/restarts. A successful escalation is not a
  periodic reminder; retry unknown/provider failures with the same identity
  and expiry under the bounded retry contract.
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

Use a controllable clock for 119.999 s / 120 s dispatch, expiry before/at/after
due time, delayed opens already due, Mac online-but-unanswered and offline,
answer on another device or local terminal, resolution-before-open, duplicate
opens with new event ids, creation-time tamper, worker failover and restart,
resolution before claim/before send/after provider acceptance, and a late tap.
Viewing/notification acknowledgment must not cancel or reset the timer.
