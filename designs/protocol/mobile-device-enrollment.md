# Mobile trusted-device enrollment

Status: account login and the mobile foundation are merged in Astation PR #72
(`7d9975c`). Protected identity and manager-review primitives are merged in
PR #74 (`0d9c3fd`). `feat/mobile-enrollment-ceremony` adds the native ceremony,
sealed key handoff, authenticated Station mailbox and Mac manager window described
below. Phone screen/coordinator wiring and live independent R9 access remain incomplete;
both mobile bridges keep
`enrollmentAvailable: false`. This document adds no Atem host wire revision.

## Existing authority

Use the accepted R9 account membership log and published Atem SDK. A phone signs
in through Auth, but only an existing native member with `manage` can add it to
the signed device list. Its initial roles are `view` or `control, view` in that
exact sorted order. Granting account management is a separate explicit action.
An enrolled phone connects directly to the selected Station and Atem; the Mac
does not have to remain online.

```mermaid
sequenceDiagram
    actor Owner
    participant Phone as Native phone adapter
    participant Manager as Trusted Astation manager
    participant Station
    participant Atem
    Manager->>Manager: Save short-lived invitation and native-only secret
    Manager->>Station: Create account-private mailbox (ID and expiry only)
    Owner->>Phone: Directly scan trusted manager QR (root, scope and secret)
    Phone->>Phone: Fresh owner confirmation; save applicant key proof
    Phone->>Station: Applicant public keys, signature and invitation MAC
    Station-->>Manager: Carry applicant request
    Manager->>Manager: Verify proof and durably bind first request
    Manager->>Manager: Save exact signed-log draft and review context
    Manager->>Owner: Show device, fingerprint and permissions
    Owner->>Manager: Fresh Touch ID / password confirmation
    Manager->>Station: Append signed R9 add at expected head
    Station-->>Manager: Stored entry or conflict
    Manager->>Manager: Verify reply and commit local log
    Manager->>Station: Authenticated encrypted handoff bound to signed add
    Station-->>Phone: Carry sealed handoff
    Phone->>Station: Read signed log using existing account token
    Phone->>Phone: Verify pinned root, own keys, roles and handoff; save durably
    Phone->>Owner: Native owner confirmation for channel access
    Phone->>Station: Independent authenticated WSS channel
    Station->>Atem: Opaque atem-ch1 frames and signed membership suffix
    Atem-->>Phone: Encrypted welcome and actual session registry
```

The direct QR scan is the independent trust input. A Station response or account token must never
supply the phone's first trusted genesis by itself. The ceremony must
authenticate both the applicant keys to the manager and the existing account
root to the phone. Showing only a phone-generated request code covers neither
direction completely. A directly scanned trusted-manager QR can pin the root;
an unverified browser link or relay-selected root cannot substitute for it.

## Implemented primitives

### Protected device identities

Apple uses `RemoteAppleDeviceIdentity` in the existing `AstationRemote` package.
The signing key and wrapping key use Secure Enclave. An X25519 private key is
sealed using a wrapping-key agreement and AES-GCM; the saved record contains
opaque enclave handles and sealed key material. The existing device-only,
when-unlocked protected store commits it before its public identity is exposed.
There is no production software fallback when Secure Enclave is unavailable.

Android uses `MobileDeviceIdentity`. Its P-256 signing key and AES-GCM wrapping
key are non-exportable Android Keystore keys. Tink generates the X25519 key;
only an encrypted record reaches an atomic file under `noBackupFilesDir`.
Keystore lock restrictions apply where supported, and every operation also
checks the device lock state. An exclusive file lock serializes identity owners.
A missing record beside existing key aliases is an incomplete setup, not
permission to generate replacement keys.

Each identity is scoped to the exact issuer and account. Its device ID and keys
survive restart. Changing Stations does not generate a new identity; the same
trusted genesis and signed membership must first be established at the new
Station. Dev and production issuers remain separate. Private keys, bearer and
refresh tokens, shared secrets and checkpoints never cross into Flutter.

Both implementations refuse unreadable, changed or corrupt saved identities.
They retain the data and require a protected reload rather than continuing
with uncertain state. Android uses pinned Tink 1.24.0 for X25519 and RFC 9180
DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305. The small HPKE
adapter isolates Tink's context API because `HybridDecrypt` does not support the
arbitrary associated data required by the SDK. The Apple and Android tests use
the same published CFRG/RFC 9180 vector with nonempty info and AAD.

Routine channel signatures use the existing five-minute owner-presence rule,
monotonic time, foreground checks and lifecycle invalidation. They accept only
the SDK's exact channel-signature request; the cached confirmation cannot sign
an enrollment or another membership mutation. Native owner-prompt presentation
and lifecycle wiring are still required in the actual phone coordinator.

### Manager approval

`RemoteNativeEnrollment` prepares an ordinary R9 `add` body through the SDK and
the existing `RemoteMembershipPublication`. It reuses
`RemoteConfirmedSigner` for fresh, one-use confirmation of the exact body.

The app-local review fingerprint binds the request ID, exact Station origin,
review expiry and complete canonical body, including the account, genesis,
head, applicant ID, both keys and permissions. This fingerprint is not a new
host signature domain or a substitute for the device ceremony. The review's
ten-minute maximum lifetime is local consent context; it does not make a
native member expire after its entry is accepted.

The review is saved before confirmation and the signature before transmission.
An existing device ID cannot be reused, including after removal. Changed
context, head movement, expiry, invalid keys, denied confirmation and uncertain
storage stop signing. A conflicting append requires a new review and fresh
confirmation. A lost reply retries the exact durably saved append; it must not
create a sibling entry. The manager reports completion only after its verified
local log contains the exact accepted entry and matching active native member.

The phone has its own completion boundary: verify the independently pinned
root, exact recipient keys and granted roles, open the authenticated sealed
account-key handoff, and atomically save the protected membership/key state.
Only then can the phone advertise enrolled status or open a member channel.

### Native trust ceremony and sealed handoff

The application ceremony uses SDK canonical JSON, length-prefixed `encodeFields`
and `hashFields`. It does not add an Atem membership action or host wire version.
The same public synthetic fixture is verified by Apple CryptoKit and Android's
Keystore/Tink/SDK implementation.

The trusted manager creates and saves a five-minute invitation before showing
its QR. The format allows at most ten minutes and expires at `now >= expires`.
It pins version, exact issuer, login owner subject, Station origin, data account,
genesis, manager device, signed head `(seq, hash)`, sorted initial roles, created
time, deadline, random 32-byte mailbox ID and random 32-byte secret. The QR is
scanned directly from that manager's native screen. It is never a browser URL.
The secret stays native on both devices; it never enters Flutter, Station,
analytics, diagnostics, memory or a log. Neither login nor a relay-selected
genesis substitutes for this scan.

The native applicant request has exactly:

```text
{body: {version, invitation, device, name, auth, encryption, roles, nonce},
 signature, mac}
```

`invitation` is `hashFields("astation-device-invitation-v1", canonical QR)`.
`auth` is the applicant's 65-byte P-256 public key and `encryption` its 32-byte
X25519 public key, encoded as unpadded base64url. The nonce is 32 random bytes.
The signing proof is over
`encodeFields("astation-device-applicant-proof-v1", canonical body)`. A fresh
native owner prompt is required; cached channel consent cannot sign it. The
normalized raw 64-byte signature and complete canonical body are also covered
by HMAC-SHA256 under the invitation secret, over
`encodeFields("astation-device-request-auth-v1", canonical body, raw signature)`.
Only a verified request is presented to the manager. Its safety code is the
first 12 uppercase hex digits of
`hashFields("astation-device-request-v1", canonical request)`, grouped 4-4-4.
The manager and phone show the same code, device name and roles.

The manager saves the first verified request before review. A retry returns the
same request; different keys or a different request cannot take over the saved
invitation, including after restart. The existing `RemoteNativeEnrollment`
prepares and signs the exact R9 `add` only after fresh manager confirmation.
A moved head requires a new review; a lost append reply retries the same saved
signature. Cancellation stays closed across restart and any uncertain local
write fences further operations.

Only a verified, committed matching `add` permits the key handoff:

```text
{context: {version, invitation, request, seq, head, entry}, enc, ciphertext, mac}
```

`request` is the request hash used by the safety code. `seq/head` identify the
accepted signed head, and `entry` is the exact manager-signed native `add` hash.
The authenticated plaintext is `{keys: [{kid, k}, ...]}`, with 1-32 distinct
32-byte account data keys. It is sealed only to the request's exact X25519 key,
using the existing RFC 9180 suite DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
ChaCha20-Poly1305. HPKE info is
`encodeFields("astation-device-handoff-hpke-v1", invitation, request)`; AAD is the
canonical context. HMAC additionally covers
`encodeFields("astation-device-handoff-auth-v1", canonical context, enc text,
ciphertext text)` under the invitation secret. The manager saves the resulting
ciphertext before publishing and reuses it on retries.

Before decryption, the phone verifies the chain against its scanned root and
head, the accepted entry and head hashes, an active native manager with
`manage`, and its exact active native member, public keys and granted roles.
A mismatched recipient, removed member, uncommitted add or changed account is
refused. The phone atomically saves the account/issuer/Station scope, own public
identity, verified membership checkpoint and account keys in native protected
storage before returning enrolled status. A save failure never reports success.

### Account-private Station mailbox

The existing authenticated Station log API carries the ceremony at:

```text
/api/remote/v1/logs/{genesis}/device-enrollments/{id}
```

| Method | Body | Result |
| --- | --- | --- |
| PUT | `{expires}` | Create immutable slot; exact retry is idempotent |
| GET | None | `{expires, request, response}`; unfilled slots are null |
| POST | `{stage: "request", message}` | Fill applicant slot once |
| POST | `{stage: "response", message}` | Fill sealed-response slot after a request |
| DELETE | None | Cancel and clear message content, keeping closed tombstone |

Each operation requires the existing native account bearer token, issued for
the exact selected Station with `astation.remote`. Foreign owners and unknown
roots receive the same generic 404. The transport refuses a QR for another
Station before fetching a token. Responses are `no-store`. Account login grants
access to carriage, never permission to sign membership or obtain the keys.

There are at most eight slots, including retained tombstones, per existing
account root. Invitations have at most ten minutes remaining at creation.
The carrier retains each slot until ten minutes after its immutable deadline.
Neither cancellation nor retries can extend or reopen it within that retention
window. Each carried message is limited to 16 KiB. Conflicting writes return
409, closed slots 410 and quota exhaustion 429; these remain distinct from an
outage. Native deadlines and saved consumption state apply even if a carrier
later forgets a tombstone. Signed log rules independently forbid device-ID reuse.

Station stores this state inside the existing owner-scoped root transaction,
using the same Postgres advisory lock and durable storage as membership. A
replica race accepts one request; a rolled-back write cannot return success.
Restart preserves the chosen request, encrypted response and cancellation.
The server checks bounded carrier shapes; native clients verify all cryptography
and exact fields. A compromised same-account bearer can poison or cancel the
mailbox and force a fresh invitation (denial of service). It cannot forge the
applicant proof, approved signed membership or authenticated key handoff.

### Mac manager window

Settings -> Security -> Trusted Phones and Tablets opens the native Add Phone
or Tablet window. It renders the QR entirely in memory, polls the selected
Station every two seconds while active, and displays only a verified applicant's
name, safety code and initial permissions. It requires an explicit code-match
confirmation followed by the existing fresh Touch ID/password gate.

`AstationRecoveryCoordinator` owns the invitation, exact review and signed
publication in its existing protected account checkpoint. A prepared device
review serializes with host, integration and recovery mutations; it cannot
overwrite another pending publication. Reconnecting or reopening the window
restores that same review. A lost append or handoff reply reconciles the stored
entry/ciphertext instead of signing or granting again. Cancellation after a
restart first reloads any signed publication and refuses to discard it while
the append outcome is unresolved. Closing/backgrounding the window hides the
private QR and invalidates pending UI callbacks; it retains the checkpoint.

Manager completion means that its committed, sealed handoff was published. The
window says to finish setup on the phone; it does not claim that a phone saved
the checkpoint or opened an R9 channel. A carrier response without the manager's
own exact durably saved ciphertext cannot make the window report approval.

## Remaining implementation

1. Add the phone's native scan/confirmation UI and connect both phone coordinators.
   Reuse existing owner authentication and account trust coordinators; do not
   place a signing key or account key in a browser form or Flutter channel.
2. Wire durable ceremony state, authenticated transport, polling cancellation
   and lifecycle invalidation into those screens and both native coordinators.
   The implemented primitives alone do not enroll a real phone.
3. Connect iOS through the existing `RemoteRelayClient` and SDK. Add the matching
   native Android socket/SDK adapter; use the current Station channels and log
   APIs, not integration service keys or a Mac proxy.
4. Wire registry, activity, prompt/takeover, approval/rules, launch and receipts
   to the existing Flutter intents. Verify physical owner prompts, revocation,
   reconnect and uncertain-outcome recovery with the Mac offline. Then enable
   enrollment capability. APNs/FCM remains a separate real-provider gate.
5. Verify interrupted setup after a committed add but before the phone's save,
   including expiry. Cancelling a mailbox does not remove a committed member.
   Do not silently roll back the log or replace the phone's identity. Finish
   explicit cleanup/resume handling before enabling enrollment for users.

Auth/Portal's dev registration is complete. No new Auth client, token scope or
host permission scheme is required for native enrollment. The unfinished
screen/lifecycle wiring and mobile coordinators are Astation work. If the
ceremony needs an additional shared SDK helper, publish its contract and ask
the Atem agent to release it; do not rebuild an Atem checkout here.

## Evidence and limits

- Both real dev phone account sign-ins, rotated refresh and Station token
  admission: [Portal #30](https://github.com/Agora-Build/Portal/issues/30#issuecomment-6719195628).
- Twelve native enrollment tests cover consent substitution, permissions, key
  validation, device-ID reuse, exact deadline expiry, durable publication,
  restart/lost reply, failed storage, head changes and removal.
- Nine Apple identity tests cover persistence, context substitution, failed
  creation, lock/background/denial, changed storage, X25519 and HPKE binding.
  Their injected software backend is test-only; these do not claim physical
  Secure Enclave or Face ID acceptance.
- Android unit tests verify the shared HPKE vector, altered info/AAD/ciphertext,
  low-order peers, bounds and canonical P-256 encoding. Emulator instrumentation
  exercises actual Keystore persistence/non-exportability, signed SDK channel
  requests, denial/background/expiry, invalidation during a prompt and damaged
  saved records. Owner confirmation in those tests is an injected callback,
  not a claim of physical biometric acceptance.
- Ceremony and native HTTP tests cover the complete signed add and encrypted
  handoff, shared Apple/Android vector, request rebinding across restart,
  altered keys/roles/MACs, uncommitted and removed recipients, save failures,
  exact origin/deadline checks, empty and nested mailboxes and retryable errors.
- A real local Postgres test uses two replicas and a new connection after
  restart; it checks competing applicants, failed-write rollback, owner
  isolation, persisted response and cancellation. The full Station suite passes
  with 566 tests; 143 optional external tests are skipped.
- All 62 Mac recovery/coordinator tests pass, including real QR decoding, exact
  manager confirmation, the shared-writer interlock, head movement during a
  prompt, account changes, and restart after lost append/handoff replies.
- No phone has been enrolled by this increment, no live agent operation was
  sent, and no hosted-execution or production-admission gate changed.
