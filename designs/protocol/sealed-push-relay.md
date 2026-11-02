# Durable sealed approval delivery

The r9 signing, identity, encryption and scheduling rules are pinned by Atem
PR #80 at `c685abab92535b167f5f2658c814f0f72541d9a1`, section R9.9.
The relay consumes `atem-client::push`; it does not implement another verifier
or accept the removed plaintext push messages.

## Ingress and persistence

Capture the current host socket's room, host ID and connection generation
before dispatch. They constrain routing; the signed hint or seen and the
stored membership chain establish identity. A claimed host ID, account login
or room alone cannot authorize a notification.

Serialize ingress with membership changes using the existing recovery-root
transaction lock. Verify the host's signature against the current signed
membership, including host trust generation, and require the carrier's host
and room to match the signed host record. Persist accepted events, refused
dispositions and resolution tombstones before returning `push_ack`. Storage
failure produces no acknowledgment. A message already accepted for durable
processing does not depend on its originating socket remaining connected.

All matching uses the full r9 approval identity, with recipient/state for
hints and device for seen. Replay uses the original receipt time; reconnect,
restart and replica failover never reset signed creation/expiry or the skew
check. Identical retries return the saved disposition. Changed signed bytes
for the same identity are refused, retaining the original event. A resolution
dominates delayed opens. Pending seen records remain bounded and survive
restart, and a seen never changes an approval or a lease.

## Delivery boundary

Provider payloads carry one original signed recipient envelope and generic
notification text. The relay never decrypts tool/summary. Enforce the complete
APNs/FCM payload budget, including provider wrappers, and use the approval ID
as the collapse ID/tag. Notification taps obtain current actionable state
from the authenticated r9 channel.

Stage claims and outcomes must be durable and generation-fenced. Recheck the
current host, recipient control role, encryption key, unresolved/unseen state,
token generation and the 15-second delivery guard immediately before each
provider attempt. External provider delivery is at least once: an ambiguous
send may be retried with the same stage/collapse identity, never a new deadline.

The existing `relayPushRegister` proves a separate relay-identity key, not
the r9 membership authentication key. Its token records must not be promoted
to r9 destinations by matching a device ID. A supported membership-key proof
for token registration is required before enabling provider dispatch. This
is a technical integration gap, tracked with Atem on #81; it does not prevent
building durable signed ingestion, sealed payload adapters or isolated tests.

Current ingress bounds are per recovery root. Before provider dispatch is
enabled, enforce the contract's aggregate pending-seen bound across every root
of an account, including historical roots. The current ingress cannot serve
as the account-wide scheduling or stage-claim implementation.

## Validation

Use real host/member keys and an isolated local Postgres schema. Exercise
host disconnection immediately after delivery, duplicate ingress on two
replicas, storage rollback before ACK, restart, resolution-before-open,
forged/wrong-generation hints and seen, recipient removal, token rotation,
and immutable scheduling boundaries. Controlled provider tests inspect actual
requests and verify that tool/summary never appear outside ciphertext.
Real APNs/FCM credentials, notification extensions, live owner authentication
and production account enrollment remain distinct validation requirements.
