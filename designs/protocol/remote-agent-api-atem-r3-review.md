# Review of Atem r9 draft at ffe840d

Reviewed pin: `ffe840d52d18aa655e15e44d44f53287ffde6522`,
[Atem PR #80](https://github.com/Agora-Build/Atem/pull/80), 2026-10-19.
Sources: the r9 appendix of `designs/protocol/atem-session-v1.md`, response r3,
and all 34 `r9-*` fixtures. No Atem checkout was edited or built.

Status: **not signed off**. The circular channel derivation is corrected and
the published cryptographic examples reproduce independently. The following
failure/lifecycle cases still need contract and fixture changes before remote
admission. Two new Recovery Kit policy choices also await the user.

## 1. High: failed membership persistence must fence live authorization

R9.3 step 3 says a failed `membership.json` write applies nothing, retains the
old head in memory and replies `busy`. Step 4's r8 fail-closed behavior only
covers the later fence writes. A verified removal/role loss can therefore
reach the host, fail at membership persistence and leave the removed member's
existing attachment, lease and queued/raw input operating on the old head.
A rename followed by failed directory fsync also leaves an uncertain durable
head while live memory is explicitly old. R9.4 likewise needs the failure
behavior when persisting a freeze fails.

Specify fail-closed behavior for all writes that persist an authorization
reduction or conflict, including write/fsync/rename/directory-fsync faults:
fence affected live authority (or halt remote admission/dispatch altogether),
do not admit new clients on the uncertain old state, and replay/reconcile
before admission after restart. A storage failure cannot silently preserve
known-revoked control. Keep r8's raw-write boundary and queued-work fences.
Add fixtures for a removal write failure before the fences, uncertain rename,
freeze persistence failure, live input and restart; don't test only a crash
after a successful commit.

## 2. Medium: delayed ingress moves escalation and can push past expiry

R9.9 uses first relay receipt `t_r + 60 s` and
`last = min(t_r + (expires_at - created_at), expires_at + 300000) - 15000`.
Our aligned plan derives deadlines from immutable original creation and
explicitly prevents relay delay/catch-up from moving them. With equal clocks,
a 300-second approval received 120 seconds late escalates at age 180 rather
than 60; the cutoff is age 405 rather than 285, permitting a provider send
after the actual host expiry.

Separate event acceptance/skew tolerance from provider delivery. Use the
original signed creation for escalation, deliver a due stage immediately on
late arrival if it remains eligible, and suppress at signed expiry minus the
agreed margin. Fifteen seconds is a reasonable technical margin; it does not
close/disable the authoritative card. If a different clock-mapping policy is
needed, specify it explicitly without resetting the unattended interval.
Add late first-open, replay/failover, clock skew and exact cutoff fixtures.
The current on-time push scenario cannot expose either discrepancy.

## 3. Medium: Recovery Kit backup writers and fresh restore rollback

R9.5 defines a symmetric `seal_key` derived from offline R, requires resealing
before every K rotation/retention change, and says restore opens the newest
blob and refuses lower versions. A newly restored device after loss of all
others has no highest-version pin; an adversarial relay can return an older
authentic blob with its matching AAD/version. The existing vector only
changes the AAD of the latest ciphertext, which is a different attack.

Specify what version/hash the offline kit or another trusted checkpoint pins,
or document that this fresh-restore rollback is undetectable and provide a
safe incomplete-data/old-kid recovery path. Do not promise newest-blob
verification without an independent floor. Bind account/root to the AEAD-
authenticated backup before publishing a recovery entry; don't treat a log
whose genesis merely copies a public recovery key as independently trusted.

Also specify how another enrolled manager seals a new backup while R remains
offline: an explicit platform key effect/storage requirement or a reviewed
public-key wrapping format is needed. Do not casually export R, derive a
second recovery signing authority, or invent a separate Swift format.
Coordinate concurrent backup versions, upload/CAS failure and interrupted
rotation with the shared core before activating a new K. Relay blob storage
alone cannot supply missing key material or freshness.

## 4. Medium: seen before open can be lost permanently

R9.9 accepts seen only after an open already naming that recipient, while the
host emits only the first device-seen and ignores repeats. Reordering across
replicas/retry paths can deliver signed seen before open (or lose the relay
delivery): it is then dropped and future client retries are acknowledged
without another emission. Mobile escalates despite a valid foreground seen.

Define durable pending seen reconciliation and/or bounded reliable host
delivery until acknowledged. Use the exact account/genesis/host trust and
session/process/approval identity for storage/dedup, not a global
`(host_id, approval_id)` key. Seen-after-resolution never reopens anything;
recheck current recipient eligibility before it suppresses delivery. Add
seen-before-open, lost delivery/retry, cross-generation and restart fixtures.

## Technical answers and implementation ownership

- Product choices from #81 remain settled; R9.13 item 1 is already resolved.
  Immediate recovery enrollment versus a 72-hour window, and rotating the
  kit after recovery versus keeping R for the genesis lifetime, are new
  questions now with the user. No answer is inferred here.
- Retain `/api/remote/v1/logs/{genesis_hash}/entries` for conditional append.
  A 409 suffix must be bounded (64 entries/256 KiB) with continuation, and
  handle a conflicting expected hash, not only a lagging sequence. Fetch and
  verify missing ranges before another fresh owner confirmation; never trust
  an unverified 409 head or change the signed body under an old approval.
  Final relay storage shapes will be reviewed with the shared core rather
  than emitted while its verifier is unavailable.
- Keep the existing encryption key's unlocked-device protection. A locked
  notification extension may show a generic notice and fetch after unlock;
  do not weaken the data-key protection or add a second push key just to
  obtain a rich locked-screen preview. The normal unlocked app can decrypt.
- Use the ceremony's existing P-256 signing identity as the native auth key;
  do not assume today's key ACL already implements r9 biometric policy.
  It currently uses `WhenUnlockedThisDeviceOnly`/`privateKeyUsage`. The r9
  platform signing adapter must enforce fresh/reused owner authentication,
  clear reuse on lock/background, and never expose a manager software key.
- R9.11's channel-clear `bad sig_c` table conflicts with R9.7's encrypted
  post-finish refusal; align the table/fixtures. Unauthenticated clear errors
  are transport diagnostics, never authority to repin or persist a freeze.

## Validation and current Astation implementation

The seven vector files pass 134 independent Python assertions using
`cryptography`, PyNaCl and RFC 8785: key derivations, entry hashes/signatures,
channel transcript/HKDF/AEAD plus replay/tamper negatives, XChaCha K backup,
HPKE opens for both recipients, push/seen and browser signatures/hash. A
separate Swift CryptoKit check passes 16 channel/HPKE assertions. These are
primitive/example checks, not a complete r9 parser, shared-core fixture run,
Kotlin/WASM conformance or protocol security sign-off.

Astation PR #58 adds a public readiness endpoint and an isolated notification
policy with deterministic tests; no remote admission or provider dispatch.
See [the API implementation status](../../docs/remote-api.md).
The verification retry reported separately on #81 is implemented in
[Astation PR #60](https://github.com/Agora-Build/Astation/pull/60), with 113
focused Swift tests passing. It is independent of r9 and not merged/deployed.
