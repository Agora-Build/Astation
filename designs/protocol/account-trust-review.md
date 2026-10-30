# Astation review of one pairing, many devices

Historical review/handoff: this records the earlier implementation and is not
the current remote-admission or approval contract. Use [r9-client.md](r9-client.md)
for shipped behavior and [remote-agent-api.md](remote-agent-api.md) for the
aligned r9 plan. Atem #81 owns handoffs; PR #80 owns the new shared contract.
Old freshness attestations, lease-taking approval answers and recovery/push
policies in this snapshot are superseded by those documents.

Reviewed Atem PR #70, `designs/account-trust.md`, at
`1e5f4d004ef3cca5adb0a21a01ca745f1602b2c8` on 2026-10-16.
This is a joint review, not an enabled wire contract. The published r7 session
compatibility gate remains in force. No Atem source was changed.

## Findings requiring agreement before implementation

1. **The 24-hour revocation claim needs a stronger freshness construction.**
   Sections 3.3-3.5 accept a fresh nonce attestation by a manager listed at the
   presented head. Suppose the log at head H lists managers A and B. H+1 removes
   B, but the relay withholds H+1 from an Atem and from B. B can keep signing H
   with new nonces; a compromised removed B can do this deliberately. The host's
   high-water mark never advances, yet its apparent freshness keeps renewing.
   Neither a monotonic clock nor a 24-hour cached-attestation limit prevents it.
   Require an agreed source of non-equivocating freshness (for example,
   intersecting, membership-aware witness quorums with transition rules), or
   explicitly narrow the guarantee to cached operation in the absence of an
   online manager. The latter changes the approved revocation guarantee and
   must be brought back to the user. Do not silently weaken it.
2. **Concurrent managers can produce two valid next entries.** An untrusted
   relay's compare-and-swap is useful storage behavior but cannot establish a
   unique head. Two managers signing different seq N+1 entries create valid
   forks; separate hosts can pin different branches. Specify prevention or
   detection, a durable fail-closed conflict state, and how recovery rebinds
   hosts. Never choose by timestamp, lexical hash order or relay preference.
3. **Signed bytes and key bindings are not yet a wire protocol.** Fix the
   canonical encoding, domain separators, hash inputs, signature formats,
   algorithm identifiers, limits, null/absent rules and rejected encodings.
   Today's verified Atem device signing key is distinct from the proposed
   native P-256 manager key. Carry the algorithm explicitly and bind every
   key to account genesis, device kind and trust generation. Neither the relay's
   existing P-256 key registry nor the storage-device list is the membership log.
4. **Enrollment needs proof of the new private keys and a bound ceremony.**
   The displayed code must commit to both devices' keys, account/genesis,
   requested roles, both nonces and an expiring single-use enrollment id.
   The applicant proves its signing key and X25519 possession. The manager
   compares that exact transcript, obtains owner authentication, and signs
   that exact add entry. Bind any delayed biometric result to the unchanged
   head and ceremony; a changed head requires revalidation. Reject swapped
   keys, replay, changed roles, cross-account requests and concurrent reuse.
5. **Removal and recovery need a complete durable lifecycle.** Define
   set_roles/removal authorization at the previous head, loss of manage/control,
   self/last-manager removal, never-reused device ids and explicit key rotation.
   Persist the new head before exposing authority; fence existing connections,
   leases, pending answers, head attestations and push registrations on removal.
   Persist pins and clock/freshness state across process restart. Account
   recovery never replaces a host's pinned genesis: local unpair/pair/verify
   establishes the new one and retains account data. Lost devices stay listed
   until explicit removal in Settings; no automatic account-device deletion.
6. **The proposal contains superseded lease-only approval rules.** Section 6a
   and some decisions/comparisons describe delivery only to a lease holder and
   closing on lease loss. The later Push-based approvals decision and r7 are
   authoritative: deliver to eligible control devices independently of leases;
   an explicit answer uses atomic acquire:true. Claude's exact offered Always
   allow rule and deny message must match r7; Codex has no Always allow.

## Agreed direction retained

Pair each host once, enroll each native controller once, independent per-device
keys, view/control/manage roles, owner-authenticated enrollment/removal, many
viewers and one active control lease, local input wins, and local host unpair
for recovery. Keep direct :8080 and relay transport under identical device and
session checks. Account login and the relay cannot authorize agent access.
Browser access remains a scoped native-approved companion, not native membership.

## API surfaces that allow testing without a phone

The local [automation API](../../docs/local-control-api.md) exercises real native
sessions, approval cards, answers and durable receipts now. It cannot grant
membership or bypass owner authentication.

Once signed formats and freshness are agreed, the relay's device-independent
API should support these operations. They are proposed, not exposed routes:

| Operation | Required authority and behavior |
| --- | --- |
| Read log after seq/hash | Account-scoped authenticated read; bounded pages, exact signed entries, explicit head; clients verify all bytes. |
| Append entry | Current manager's signed entry and expected head; transactional append, idempotent same entry, conflict on another head. No login-only reset/delete route. |
| Enrollment rendezvous | Expiring applicant proof and transcript commitment; no authority until a manager signs after native owner authentication. |
| Read/request head proof | Bound account/genesis/host/nonce and hard deadline; relay transports the proof and cannot mint freshness. |
| Register push address | Member key proof plus genesis, key/generation and platform; token possession alone grants nothing. |
| Host push challenge/proof | Manager-authorized host key and current generation; see [push proof draft](approval-push-proof.md). |
| Push event/receipt | Signed bounded event, durable acceptance before acknowledgment, idempotent event id, resolution wins, expiry and revocation rechecked before provider send. |

Headless test clients generate real independent keys and follow the same API
and signed contract as a phone. They must never use an administrator override,
SSO impersonation, a test production credential, or a skip-verification flag.

## Required shared fixtures

Valid genesis/add/role-change/remove, wrong account/root/key/algorithm,
noncanonical bytes, unauthorized manager, applicant key substitution, replayed
ceremony, concurrent appends and equivocation, removed-manager fresh-nonce
attack, withheld head, stale/future proof, exact-deadline expiry, backward clock,
restart, revoked live controller, last-manager recovery, and push registration
rotation/removal. Include complete signed bytes and expected durable state.
An HTTP harness can run all of these without a mobile UI; real platform
keystore/biometric and APNs delivery remain separate hardware/provider tests.
