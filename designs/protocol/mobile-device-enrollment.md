# Mobile trusted-device enrollment

Status: account login and the mobile foundation are merged in Astation PR #72
(`7d9975c`). Protected identity and manager-review primitives are implemented on
`feat/mobile-device-enrollment`. The phone/manager ceremony and live independent
R9 access are still incomplete; both mobile bridges keep
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
    Phone->>Phone: Create and durably save protected device keys
    Owner->>Phone: Verify enrollment context with trusted manager
    Phone->>Manager: Verified applicant keys and requested roles
    Manager->>Manager: Save exact signed-log draft and review context
    Manager->>Owner: Show device, fingerprint and permissions
    Owner->>Manager: Fresh Touch ID / password confirmation
    Manager->>Station: Append signed R9 add at expected head
    Station-->>Manager: Stored entry or conflict
    Manager->>Manager: Verify reply and commit local log
    Manager-->>Phone: Trusted root / entry binding and sealed account-key handoff
    Phone->>Station: Read signed log using existing account token
    Phone->>Phone: Verify pinned root, own keys, roles and handoff; save durably
    Phone->>Owner: Native owner confirmation for channel access
    Phone->>Station: Independent authenticated WSS channel
    Station->>Atem: Opaque atem-ch1 frames and signed membership suffix
    Atem-->>Phone: Encrypted welcome and actual session registry
```

The arrows between phone and manager describe the required ceremony, not an
implemented rendezvous API. A Station response or account token must never
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

## Remaining implementation

1. Implement the phone/manager rendezvous and the two-direction trust ceremony.
   Bind account, selected Station, applicant keys, fresh request nonce, trusted
   genesis, exact entry and expiry. Specify bounded authenticated storage,
   cancellation, retries and one-use completion before opening a live endpoint.
2. Add the native manager's Add Device review and the phone's confirmation UI.
   Reuse existing owner authentication and account trust coordinators; do not
   place a signing key or account key in a browser form or Flutter channel.
3. Implement authenticated sealed account-key transfer and the phone's durable
   completion checkpoint. A relay acknowledgment alone never completes setup.
4. Connect iOS through the existing `RemoteRelayClient` and SDK. Add the matching
   native Android socket/SDK adapter; use the current Station channels and log
   APIs, not integration service keys or a Mac proxy.
5. Wire registry, activity, prompt/takeover, approval/rules, launch and receipts
   to the existing Flutter intents. Verify physical owner prompts, revocation,
   reconnect and uncertain-outcome recovery with the Mac offline. Then enable
   enrollment capability. APNs/FCM remains a separate real-provider gate.

Auth/Portal's dev registration is complete. No new Auth client, token scope or
host permission scheme is required for native enrollment. The unfinished
ceremony, Station rendezvous and mobile coordinators are Astation work. If the
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
- No phone has been enrolled by this increment, no live agent operation was
  sent, and no hosted-execution or production-admission gate changed.
