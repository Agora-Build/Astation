# Atem Device Verification

This work implements Astation's side of E2E build steps 0-1 from
[Atem PR #38](https://github.com/Agora-Build/Atem/pull/38). The wire contract
and known-answer vectors were taken from `bd77a4b6` and checked unchanged
at `4e61b597`. PR #38 also contains ongoing step 2a work (sealed device
storage keys and unlock); those messages are a separate implementation.

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
HPKE ciphertext listed in Atem's design. Randomized signatures are verified
and the fixed Rust HPKE output is opened to its specified K.

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
test verifies forwarding all new frames and signed mode/grant payloads.

Before release, complete a real `atem pair` against an isolated account,
confirm both codes, test Touch ID cancellation and success, relaunch the
Mac app to check pins/epochs, and confirm a changed key cannot obtain K.
Keep step 2a interoperability separate until Atem's draft escrow/unlock
contract is complete.
