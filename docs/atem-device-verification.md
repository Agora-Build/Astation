# Atem Device Verification

This work implements Astation's side of E2E build steps 0-1 and 2a from
[Atem PR #38](https://github.com/Agora-Build/Atem/pull/38). The wire contract
and known-answer vectors were taken from `bd77a4b6` and checked unchanged
at `4e61b597`. Step 2a uses the storage-key/unlock contract and fixed
vectors in the merged PR #38 design at `aedbb9d`. Atem also implements
step 2b, keeping account keys in its key agent.

## Protocol And Trust

The existing authenticated WebSocket carries `verifyCommit`, `verifyKeys`,
`verifyReveal`, `deviceVerified`, and `verifyAbort`. The relay forwards
opaque JSON on the existing device/connection envelope. It stores no new
verification data and decides no cryptographic trust.

Astations bind attempts to the authenticated Atem ID, the connection
generation, the data account, and a fresh 32-byte nonce. Attempts expire
after three minutes. The revealed keys must match the original commitment
before the Mac displays a safety code. Approval requires matching codes
and Touch ID. The first verification also requires confirmation that the
complete recovery kit was saved. Denial, abort, expiry, and connection
replacement invalidate pending approvals.

Safety-code and recovery dialogs run without blocking the main queue.
A peer abort, disconnect, or timeout dismisses the active dialog and
invalidates any pending Touch ID request. A retry can start immediately;
callbacks from an earlier prompt cannot approve the new attempt.

The Atem client must use its authenticated Atem ID in `verifyCommit`,
rather than its instance UUID. It must receive an explicit safety-code
answer from an interactive terminal; redirected stdin or unavailable
input must not be interpreted as a code mismatch. SSO pairing and an
authenticated connection can remain available after E2E verification
fails. Check `atem cred status` for device trust.

Certificates include the ceremony transcript. The certificate is signed
at epoch E and the accompanying account state at E+1. Device pins and the
epoch counter are saved together only after every signature/grant succeeds.
Signatures use the 65-byte P-256 X9.63 public key and low-S 64-byte r||s.
Grants use CryptoKit's RFC 9180 X25519/SHA-256/ChaCha20-Poly1305 base mode,
the specified length-prefixed `atem-grant-info-v1` context, and empty AAD.

`encryptionMode` carries a signed state from this Mac's local approved
state. Relay reports supply migration statistics; they cannot authorize a
downgrade, overwrite a local mode/key ID, or delete local account keys.
`keyRequest` needs the authenticated device's exact pinned public key.
Legacy fingerprints and unsigned wrapped grants do not authorize access.

## Encryption Migration Completion

The lifecycle and security invariants are specified in
[designs/e2e-encryption.md](../designs/e2e-encryption.md). Astation captures
the authenticated device, connection generation and account, verifies the
device-signed `atem-migration-complete-v1` and its account-key proof, and
persists the accepted report before asynchronous dispatch. Completion uses
that durable journal, so Atem can disconnect immediately after delivery.
Final state, epoch and signature commit together before publication;
duplicates reuse the committed result. Startup/reconnect resume accepted
work and retry key-access, signing and persistence failures.

The reporting pin and verification epoch must remain current at commit.
Revocation or re-verification invalidates pending authorization, including
when the same keys are reused; a fresh verified report can finish the still
pending migration. Relay modes and counters cannot authorize final state.
A local key with no approved signed state starts in `enabling`, and final
modes cannot be set through the generic owner-change method.

Updated Atem clients read migrated memory, skill history, vault summaries
and vault entry history back, check field formats and ciphertext
authentication, and sign the completion inside the unlocked key agent.
They use a five-second bounded socket flush before exiting. This is delivery
assurance; it does not require Astation to commit before the client exits.
Unsigned legacy completions fail closed. Update both the client and its
running key agent before live migration verification.

## Storage-Key Escrow And Unlock

The authenticated connection also carries `unlockRequest`, `unlockGrant`,
`unlockDenied`, `storageKeyRotate`, `storageKeyAck`, `storageKeyRejected`,
`storageKeyConfirm`, and `storageKeyAbandon`. The relay forwards these
opaque messages in order; it stores no keys or additional protocol state.

Storage keys live in the same protected Keychain record as the device pins.
Formats 1 and 2 load without changing key material and upgrade to version 3
on their next write. Version 3 also stores migration journals and device
verification epochs. Older builds refuse unsupported versions, retaining
the record instead of dropping escrow, replay history or migration state.
Each `(device_id, device_pub)` binding has at most one current and one pending
key, the exact acknowledged rotate statement and signed acknowledgement,
and a permanent set of acknowledged key IDs. A byte-identical retry returns
the stored acknowledgement, including after a restart. A different rotate
cannot replace an acknowledged pending key. A signed confirm, an unlock of
the pending key, or a rotate naming it as the old key promotes it. An unlock
of the current key retains pending. An exact signed abandon drops only the
pending key and preserves its replay history. Reverification with a new
device encryption key starts a separate binding without releasing old keys.

Unlock validates the signature against the pinned unlock-auth Ed25519 key,
the account and authenticated device ID, an empty ticket, a valid lowercase
key ID, the ephemeral X25519 key, and a five-minute arrival-time window before
opening a prompt. The prompt shows device name, boot ID, request time, and
last unlock. Approve requires Touch ID with no password fallback. Deny and
revoke removes the local E2E verification pin; the device must verify again
before receiving further grants. Relay-wide signed device revocation is a
later protocol step.

`unlockDenied` includes `revoked: true` after Deny and revoke has persisted,
and when Astation no longer has a verification pin for the authenticated
device in this account. Atem records this signal and verifies with fresh
keys at its next `atem pair`, as implemented in
[Atem PR #39](https://github.com/Agora-Build/Atem/pull/39). For a device with
a current verification pin, ordinary denial, malformed requests, invalid
signatures, and unavailable storage keys omit the flag. These errors do
not claim revocation, including through the
reason-text fallback used by older Atem builds. Missing flags decode as
false for compatibility.

Approvals expire after three minutes. Disconnects cancel the prompt;
replaced connections, changed accounts or pins, and stale callbacks cannot
release a key. Only one verification, recovery, or unlock prompt is shown
at a time. Rotation and settlement need the device signing-key signature
and no Touch ID. All replies use the request's captured connection generation.
Persistence succeeds before an acknowledgement or unlock grant is sent.

Unlock seals only the requested storage key with the specified
`atem-unlock-info-v1` request-hash context and signs `atem-unlock-grant-v1`.
Rotation opens `atem-storage-key-info-v1` and signs `atem-storage-ack-v1`.
Both use RFC 9180 X25519/SHA-256/ChaCha20-Poly1305, empty AAD, and low-S
P-256 signatures. No storage-key bytes appear in UI or logs.

## Keys And Recovery

The E2E signing key is separate from the relay authentication key. It uses
the Secure Enclave without a software fallback. A second Secure Enclave
key seals the X25519 private key. The distinct 32-byte recovery secret R
derives the Ed25519 recovery signer using `atem-recovery-sign-v1`; R is
never account key K. Epochs, pins, and identity material persist in a
dedicated Keychain item. Unreadable items are retained rather than reset.

The kit adds `Recovery key:`. Saving uses an owner-only temporary file,
flushes it, and replaces the destination atomically. Existing `AEK1` kits
still export K separately. Restoring an E2E identity, backup escrow, and
the 72-hour recovery signing-key rotation belong to later build steps;
the legacy ID-only restore refuses a kit containing R.

Identity storage uses the Data Protection Keychain with
`WhenUnlockedThisDeviceOnly`. It requires a provisioned app with authorized
Keychain entitlements. Unsigned/ad hoc processes cannot access this storage
(`errSecMissingEntitlement`, -34018); there is no weaker storage fallback.
The separate login Keychain does not enforce this accessibility class.

## Personal-Team Local Signing

An Xcode Personal Team can provision local verification without a paid
membership or access to an organization's account. In Xcode Settings >
Accounts, select your personal team and create an Apple Development
certificate. Its Team ID is distinct from the identifier in parentheses
in the certificate's name.

After building the C++ core, run:

```sh
bash scripts/verify-local-signing.sh PERSONAL_TEAM_ID
```

The command requests a profile only for the specified team and the isolated
bundle ID `build.agora.astation.local.<lowercase-team-id>`. It checks actual
Data Protection Keychain accessibility, packages `.build/Astation Local.app`,
and runs the Swift XCTest suite in a provisioned host. XCTest bundle names
are located through SwiftPM's current build output, supporting both native
SwiftPM and Xcode build systems. The host wraps a copy of Xcode's test
driver; installed Xcode binaries are retained. Tests receive a minimal
environment, and `ASTATION_REQUIRE_KEYCHAIN_TESTS=1` makes missing Keychain
entitlements fail instead of skipping these integration tests.

Personal Team profiles expire after seven days. Rerun the command to renew
the profile and re-sign the app. All build products,
profiles, certificate metadata, and logs stay under ignored `.build/`.
The command executes only the probe, bundled-resource check, and tests;
it does not start Astation's UI or a relay connection. The local app does
not register the production `astation` SSO callback URL scheme.

After rebuilding, quit an older development app before opening the exact
`.build/Astation Local.app` produced by the command. Copies such as
`Astation Cancellation Fix.app` have the same bundle ID and Keychain group;
opening another copy can bring the already-running old process forward.
An older copy refuses a newer identity format and reports it as unreadable.
Check the process's executable path or the startup `App bundle` and `Atem E2E`
log entries to confirm which build is actually running. An unreadable-identity
message alone does not prove a signing mismatch. Current builds distinguish
an unsupported newer format and tell you to update; all such failures retain
the existing identity and device pins.

`package-dev-app.sh` also accepts `ASTATION_SIGNING_IDENTITY` and
`ASTATION_PROVISIONING_PROFILE` together, plus `ASTATION_DEV_BUNDLE_ID` and
`ASTATION_DEV_BUNDLE_DIR`. It checks profile expiry, authorized bundle/group,
and certificate fingerprints before applying the entitlements. Without
these options it preserves ad hoc development packaging.

This resolves local verification storage. Production release packaging
still needs an authorized distribution profile, certificate, and
notarization before shipping this flow.

## Validation

The Swift known-answer suite checks every public key, encoding, commitment,
safety code, transcript, statement, sealed-output digest, signature, and
HPKE ciphertext listed in Atem's design, including every step 2a vector.
Randomized signatures are verified and the fixed Rust HPKE outputs are
opened to the specified account and storage keys.

```sh
swift test
swift build -c release
ctest --test-dir build --output-on-failure
cargo test --manifest-path relay-server/Cargo.toml
```

The real Secure Enclave test requires an unlocked Mac; it skips when the
hardware is absent or locked. Unprovisioned `swift test` runners explicitly
skip Data Protection Keychain tests; the local signing command requires
them. The real protected-identity test creates a synthetic identity,
verifies signatures, and reloads recovery material, device pins, account
state, and epochs from the protected Keychain. Its temporary item is removed
afterward. Controller tests cover approval denial,
unsaved recovery, replay, expiry, abort, replacement, account changes,
failed persistence/signing, and exact pinned-key grants. A real relay socket
test verifies forwarding all new frames, ordered abandon/rotate delivery,
and rejection of replies addressed to replaced sockets. Storage-key tests
cover restart/re-ack, explicit and implicit confirmation, retained pending
keys, abandonment, permanent replay history, fresh device bindings, strict
parsing, invalid signatures/time/tickets, and stale approvals. A provisioned
integration test escrows and reloads a real protected key, opens its unlock
grant, and checks replay rejection through the Secure Enclave identity.
Migration tests cover immediate local/relay disconnect, delayed work,
duplicates, restart, persistence/signing/key failures, reconnect, old-report
replay after identical-key re-verification, and revocation around commit.
Swift and Rust share an independently calculated migration-proof vector.

Before release, complete a real `atem pair` against an isolated account,
confirm both codes, test Touch ID cancellation and success, relaunch the
Mac app to check pins/epochs, and confirm a changed key cannot obtain K.

For live step 2a verification, run `atem pair` and check `atem cred status`
reports the storage key held by Astation. Then run `atem cred lock` and
`atem cred unlock`, approve Touch ID on the Mac, and confirm storage-key
rotation. Test Deny and a disconnected unlock before approving a fresh
request. Relaunch Astation and repeat unlock to check persistence. Finally
enable account encryption in Astation and run `atem sync` to verify that K
stays in Atem's key agent. Automated crypto/controller tests do not exercise
the user's physical Touch ID interaction or production relay pairing.
