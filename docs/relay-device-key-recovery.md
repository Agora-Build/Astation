# Relay Device Key Access and Recovery

The relay device key proves this Mac's Astation identity. It is separate from
the Account Recovery Kit (ID and relay URL) and the account-data encryption
recovery key. Device-key recovery keeps the Astation ID, existing pairings,
and account data.

## Access failures

Settings > Security > Relay Device Key shows the reason verification is
unavailable. The warning in the menubar opens that section.

- Restricted or temporarily unavailable Keychain access retries after 30,
  60, 120, and 240 seconds, then at most once every five minutes.
  Automatic reads suppress Keychain authentication UI.
- Denied/cancelled access and other access errors wait for **Retry Key Access**.
  This explicit action permits a Keychain prompt.
- An undecodable key or a stored Secure Enclave key that this Mac cannot
  use waits for an explicit repair. Network changes do not retry the key.

Relay connections stop while key access has failed. The app does not claim
that legacy relaying remains available for a registered identity.

## Repair an unusable stored key

1. Choose **Repair Device Key** in Settings > Security.
2. Authenticate with Touch ID or the Mac password, then confirm replacement.
3. Ask the relay administrator to run the reset command shown by Astation,
   in a container serving the displayed relay:

   ```bash
   station-relay-server admin forget-key '<astation-id>'
   ```

4. Choose **Complete Relay Reset**, then **Reset Is Done - Reconnect**.

Repair updates the existing Keychain item atomically. An unsuccessful update
keeps the original item. If the item has become readable since repair was
requested, Astation leaves it unchanged and asks you to retry access.

The relay pause is saved before changing the key and survives app relaunch.
Network events cannot bypass it. Starting a connection does not clear the
pause: the relay must return `registered` or `verified`. If the relay rejects
the key, Astation stays paused so the reset can be completed without a
reconnection loop.
If another repair is attempted while recovery is pending, a failed update
keeps the existing recovery pause.

If a readable key is rejected, **Recover Relay Trust** prepares the same
administrator reset workflow while keeping that key. This covers a lost
Keychain item or an account restored from another Mac; replacement is not
needed when the current key can sign.

The app does not run an administrator command against the relay. Follow the
[admin-reset runbook](../DEPLOY.md): a reset retains pairing bindings and
reopens trust on first use, so reconnect the intended Mac promptly. Device
removal from an Agora account revokes the device instead of performing this
recovery reset.

## Implementation and verification

`RelayIdentityKey.swift` preserves typed Keychain/CryptoKit failures and uses
add-only initial persistence, so another instance's newly created key is not
deleted. `RelayIdentityKeyManager.swift` owns key-access retries independently
of WebSocket reconnects. `AstationHubManager.swift` owns the relay pause and
clears it only after verification. Settings authenticates and rechecks the
identity, relay, and repair eligibility around confirmation.

Focused tests cover error classification, background key access, retry
timers, authentication denial/cancellation, failed atomic replacement, an
isolated real Keychain item, recovery-pause persistence, rejected reset
attempts, stale socket callbacks, and resynchronization of existing pairings:

```bash
swift test --filter 'RelayIdentityTests|RelayIdentityKeyManagerTests|RelayIdentityKeyRepairActionTests|RelayIdentityKeyRepairRecordTests|RelayIdentityRecoveryLifecycleTests|IdentityRelayReconnectPolicyTests|RecoveryKitTests|DeviceAuthenticationTests'
```

The real Keychain test uses a fresh test service/account and removes that
item afterward. It never repairs or deletes the user's production key.
Hardware-specific checks remain: signing while the screen is locked,
Keychain denial after rebuilding/re-signing, and password fallback on a Mac
without Touch ID. Run destructive recovery scenarios against isolated
identities and local relays.
