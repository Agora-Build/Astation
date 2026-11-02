# Astation review of Atem's remote API response r2.1

Reviewed 2026-10-19. Sources: [Atem PR #80](https://github.com/Agora-Build/Atem/pull/80)
at immutable pin `c2ef8ff4f686d0a63826696f7c97aefd84985984`, especially
`designs/protocol/remote-agent-api-atem.md` and `designs/account-trust.md`,
and the [#81 reply](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6275590949)
and [recovery correction](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276170813).
The PR body retains superseded attestation/reset text. This review uses the
pinned files and the correction, not that body.

Follow-up: the [confirmed #81 reply](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276488130)
settles all three product questions and confirms v0.7.2 retains device_id.
The [coordination update](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276913191)
makes #81 the working handoff channel and PR #80 the shared design owner.
Atem acknowledged the handshake issue and is drafting its correction. The
findings below describe c2ef8ff; a corrected pin and vectors are still needed.
Current Astation requirements are in [remote-agent-api.md](remote-agent-api.md).

**Architecture agreement permits drafting r9 and its fixtures. It is not
channel/security sign-off or permission to enable remote admission.** The
circular handshake below blocks implementation of `atem-ch1` as written.
The product questions recorded during the initial review are now resolved
by the confirmed handoff; they no longer block r9 drafting.

## Agreed direction

| Area | Astation response |
| --- | --- |
| Independent clients | Agree. Mac, mobile and services have their own keys, channels and attachments to the same original host/session. A running Mac is not required. |
| Relay boundary | Agree. Login/presence/rooms route traffic; the signed membership chain, pinned host key and endpoint proof establish authority. |
| Membership | Agree with signature verification, a durable head, rollback refusal, applying authenticated suffixes and revocation fences before sender admission, and preserving r8 journal guarantees. A removed/unknown carrier can deliver a valid signed removal without gaining access. |
| Revocation guarantee | The proposal provides eventual propagation, with no bound on a hidden removal. A durable head prevents rollback after observation; it cannot reveal an unseen head. Describe that limit explicitly; do not claim the former freshness bound survives. |
| Conflict handling | A fail-closed freeze and local host re-pairing can be specified, but honest concurrent signing must be covered as described below. No manager or recovery signature lifts a freeze. |
| Principals | Agree with distinct native members, scoped expiring non-delegating services, and short-lived native-approved browser companion grants. Management is separate from host control. |
| Host identity | Agree with a separate host channel key pinned by the safety ceremony, account genesis and host trust generation. Rotating/unpairing must invalidate the old binding. Hostnames and relay labels are not replacement identity. |
| Shared core | Agree that Atem owns `crates/atem-client`, including verifier, channel, client machines and fixtures. Swift/Kotlin/JS bindings consume it; native key storage, biometric policy, persistence, transport and UI remain platform adapters. No copied Swift cryptographic protocol. |
| Version and behavior | r9 only for this new admission mode; no compatibility fallback. Keep r8's atomic prompt acquire/confirmed takeover, lease renewal, explicit terminal control, lease-free approvals/revocation, receipts and whole-message history. |
| Work order | Draft exact formats and fixtures, review/pin them, build the shared core and host, then integrate relay/native clients and run the Mac-off matrix. Browser control has its own companion-code threat-model review. |

Removing attestations, renewal clocks and the routine signing key simplifies
the proposal, but does not prove bounded revocation. Remote enablement remains
gated on an explicit threat-model agreement, final schemas and passing vectors.

## Findings before the r9 pin

### 1. High: channel_accept has a circular decryption dependency

In `remote-agent-api-atem.md:264`, `channel_accept` exposes only `e_h`, `n_h`
and `ct`. At lines 265-270, deriving `k_h2c_hs` requires `th2`, which contains
`genesis_hash`, `head_seq` and `head_hash`. Those values are carried inside
`ct`, encrypted with that same key. A client behind the host cannot decrypt
the reply to discover the head needed to derive its key.

Choose a reviewed construction with a complete, non-circular transcript/key
schedule. For example, making the challenge head public and authenticating
it in the transcript removes this particular dependency; alternatively the
first encryption key must use only already available inputs, with the head
bound into the subsequent authenticated transcript. These are correction
directions, not a cryptographic security review of either construction.

The r9 appendix must fix exact encodings, signing inputs, HKDF salt/info,
nonce/AAD and counter domains for handshake and application records, and
publish full vectors. Include divergent client/host heads, tampered head,
wrong host/root/trust generation, all-zero X25519 shared secret rejection,
wrong signature/tag, replay/direction confusion and disconnect at every step.
Set explicit record/byte/counter limits requiring a new channel before key
exhaustion, with secret erasure on failure/close. "Cannot wrap in practice"
is not an executable limit. The suite's name or "SIGMA-I shape" is not a
substitute for review of its actual construction.

### 2. Medium: a fork does not establish that a manager key was stolen

Lines 137-145 describe a valid conflicting entry as proof of compromise and
say relay transactional append makes honest races practically impossible.
Two honest managers can sign different successors to the same head. An
adversarial relay can solicit or expose both; its CAS is not consensus or a
security guarantee.

Also, `entry_hash` includes the signature. P-256 can produce distinct valid
signatures for the same body, so re-signing an identical entry need not give
the same hash. Define exact retry bytes and durable publication rules, and
test this case; a legitimate signature retry must not be reported as proof
of key theft.

Specify what happens to both devices and already-connected hosts in that
case. If the accepted policy is freeze plus local re-pairing even for honest
concurrency, state the availability cost and use neutral "conflicting signed
membership history" UI. Add fixtures for honest concurrent adds, a fork
delivered by an unknown carrier, a fork signed by a removed manager, and
different hosts initially observing different valid successors. Do not
silently merge branches or let a relay choose a new trust root.

### 3. Medium: recovery entry and data recovery need an exact shared format

The example at lines 167-176 uses `device_sign_pub`/`device_enc_pub`; other
entries use `auth_key:{alg,pub}`. Publish one unambiguous recovery action and
signer representation. Bind account, genesis, predecessor/head, sequence,
new member ID, auth/encryption key algorithms and keys, and exact permitted
roles. Verify only with the genesis-pinned recovery key; reserve the recovery
signer namespace. It must not remove a device, change the recovery key,
reset a head, bypass a revocation fence or lift a freeze.

The recovery signing secret alone cannot restore an independently generated
account data key `K`. Astation currently has distinct signing-recovery and
data-key export formats. Specify the versioned kit and authenticated K
envelope/export, account/genesis/kid binding, retained key generations,
rotation/backup-update behavior and corruption handling. Do not promise
data recovery from a signing seed without a durable recoverable copy of K.

Astation owns generating and pinning the recovery public key before initial
account/genesis commitment, requiring a confirmed saved kit, and offering an
offline export for a password manager or printed phrase/QR. No secrets go
into relay records, logs or shared memory. Restore must validate kit/account
binding and durably restore K before reporting data recovery; an interrupted
restore must be retryable without silently creating a new key or trust root.

The kit may enroll a replacement manager into the existing chain after loss
of every native device, as confirmed on #81. The final schema follows that
decision and cannot lift a security freeze.

### 4. Medium: sealed hints and active-user seen need interoperable schemas

Approve the privacy direction: tool/summary are sealed independently to
currently authorized recipients, and the relay never receives their clear
text. Specify the X25519 recipient key separately from the P-256/Ed25519
authentication key and bind it in signed membership. Fix the HPKE suite,
info/AAD/signature domains and recipient key ID. Bind account/genesis, host
key/trust, exact approval/session/process, immutable creation/expiry,
recipient and ciphertext digest. Resolution needs the same complete identity
and must dominate a delayed open.

Send one bounded recipient envelope to APNs/FCM, not the whole fanout array;
APNs's payload budget includes the `aps` wrapper. The iOS notification service
extension opens sealed content only with a suitably protected notification
key and `mutable-content: 1`. If the key is unavailable while locked, show a
generic hint and reconnect; never fall back to plaintext or attempt an
interactive biometric signing prompt in the extension. Neither decrypted
hint nor provider delivery creates an actionable approval: fetch host state.

An accepted `seen` signal must be from an authenticated current eligible
device, bound to the exact approval identity and deduplicated across replicas.
Specify its signing/channel proof, timing, retention, revocation and races
with resolution. Emit only after the card is rendered in a focused foreground
window with an active user; background delivery, an unopened notification
and an unattended window do not qualify. It never answers, acquires a lease,
closes a request or reopens resolved state. Whether it suppresses escalation
is a product decision, not implied by defining the signal.

The original creation time cannot move on retry/reconnect. Connected desktops
are a routing hint only. Suppressing provider delivery near expiry must not
label a still-pending request expired or disable a still-valid answer early.
At the reviewed pin the comment's 0/60 schedule and file's 60/180 schedule
disagree; the confirmed policy is now 0/60 with active-user seen suppression.

### 5. Clarify atomic suffix admission and failure recovery

Lines 101-107 combine per-entry validation/fsync with "an invalid entry changes
nothing". Define whether the entire bounded suffix is validated before one
atomic durable commit, or valid prefixes can commit before a later refusal.
Fix the returned head/error accordingly. No welcome or remote effect may
overtake a committed removal fence. Test a valid removal followed by an
invalid add, concurrent suffixes, write/fsync failure and crash/replay before
admission. Set entry-count/byte/evidence bounds without allowing rejected
traffic to create unbounded storage or signature work.

## Product decisions resolved on #81

The user-confirmed reply settles these questions; the earlier alternatives
are historical and are not current requirements.

| Decision | Confirmed behavior |
| --- | --- |
| Approval escalation | Desktop OS immediately when none connected; mobile at 60 s if unanswered and not actively seen; optional desktop reminder/mobile immediate preference; suppress near expiry without changing request expiry. Supersedes 60/180. |
| Loss of every trusted native device | Kit restores K and enrolls a replacement manager into the existing chain; hosts keep working without re-pairing. Lost records require explicit removal; kit cannot lift a freeze. Supersedes mandatory re-pair after ordinary device loss. |
| Manager biometrics | At most five-minute reuse for routine channel signing, cleared on lock/background; fresh Face ID/Touch ID for enrollment, removal and recovery. Enforced by platform key policy. |

An enrollment/recovery signature must bind the exact ceremony, applicant keys,
account/root, requested roles, nonces and current predecessor. A delayed
biometric result cannot authorize a changed transcript. A reuse window is a
local convenience, never a host claim that biometrics occurred and never
background permission for membership edits.
Native owner-authentication UI must retain an OS password/passcode fallback
where supported, including a Mac whose lid is closed. Astation does not
collect the user's OS password.

## Historical items already complete

The four r8 edits are confirmed in the
[implemented r8 review](agent-control-api-atem-r6-review.md), including the
final merged pin `4f87bab1289848cb6a0da5707d2e7830eb5c057d`:

1. A halted journal leaves the link authenticated but unadmitted; no welcome,
   and requests get their family busy refusal. A failure to persist even the
   refusal still closes without replying under section I.
2. Chat close without a binding closes only the sender's own conversation.
3. Only valid history requests count toward 8/s; malformed requests each get
   their sequenced error, subject to independent transport/abuse limits.
4. Invalid non-opaque result IDs are omitted from correlation without changing
   the completed receipt or allowing a prompt retry.

Astation [ships r8](r9-client.md). There are no VisualizeRequest/VisualizeResult
handlers or message types in Sources, Tests, relay-server or webapp; only
historical handoff text remains. Atem may remove its types/stub reply.

## v0.7.2 re-verification and K

Current `AtemE2EIdentity.completeVerification` atomically replaces the verified
pin for the same device ID, including encryption, signing and unlock-auth
keys, advances the verification epoch and seals the existing K to the new
encryption key when K is available. Account state and keys commit before the
response leaves. No new K is generated to hide an unavailable existing key.
Replacing a pin invalidates accepted migration work tied to the previous
pin/verification epoch, even after reload.

Regression coverage in `AtemE2EIdentityTests` and
`AtemEncryptionMigrationTests` checks durable replacement, new-key decryption,
old-key refusal, failed signing/storage preserving the old record, and old
migration completion rejection. These exercise today's pairing identity;
they do not establish r9 membership or cross-device recovery.

Atem confirmed v0.7.2 retains atem_id in config.toml, so the tested same-ID
path applies. A future new-ID replacement would need an authenticated
relationship in the confirmed ceremony/membership design or explicit user
selection. Never identify replacement by hostname, relay room or SSO.

## Implementation gate and next handoff

Atem is drafting r9 and shared fixtures for the agreed architecture and
confirmed policies, resolving the technical findings above. Astation
will consume the pinned shared core, implement native enrollment/recovery and
encrypted notifications, store/route signed records and run independent
controller/host tests. No new wire fields, remote admission, push scheduler
or recovery trust migration are enabled by this documentation or the current
regression tests.

Required next artifacts: corrected channel profile/vectors, exact membership
and recovery schemas, sealed-open/resolution/seen vectors, explicit suffix
failure semantics, and a versioned shared-core binding and
storage/effect contract. Keep Astation PR #58 and Atem PR #80 draft until
the shared security contract is pinned and independently verified.

## Validation

The focused Swift command
`swift test --filter 'Atem(E2EIdentity|EncryptionMigration)Tests/testReverification'`
passes four tests: three new replacement/failure/reload regressions and the
existing identical-key re-verification fence test. These use injected storage
and software crypto with real HPKE encryption; they do not test provisioned
Keychain, biometrics, r9, a live v0.7.2 host, or APNs/FCM delivery. No Atem
checkout was edited or built. The current code has no Visualize messages or
handlers. Documentation links and whitespace are checked separately.
