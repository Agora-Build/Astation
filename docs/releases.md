# macOS Releases

Astation's protected credential store and Atem E2EE identity use the Data
Protection Keychain. A public release must have an authorized application
identifier and Keychain group. An unsigned or ad hoc package cannot provide
these features. Developer ID signing and notarization also let Gatekeeper
validate downloaded apps and installers.

## Current readiness

The last public release is `v0.4.19`. The next planned release is `v0.4.20`,
including the merged credentials UI, embedded Touch ID, project spelling and
durable encryption migration. No new tag has been pushed for this preparation.

As of 2026-10-11, the user does not have a paid personal Apple Developer
membership available. GitHub has no Apple release-signing credentials. The
local Apple Development certificate and seven-day, one-device Personal Team
profile are for the isolated Local.app and cannot authorize public distribution.
Public release remains blocked until the prerequisites below are available.
The existing Local.app can continue to provide local verification; keep its
team, bundle identifier and Keychain group when updating it.

Settings > About, the last item in the sidebar, shows Version and Build
timestamp. Both development and release packaging run `scripts/stamp-app-build.py`
before signing. Releases show their release version; development builds show the Git description,
including the revision and `dirty` suffix for uncommitted changes. The UTC
timestamp records packaging time and stays unchanged when the app is launched
or copied. Development packages without Git metadata show "Development".
Unpackaged binaries without metadata report that it is unavailable.

## Personal account prerequisites

Use the intended paid personal Apple Developer account. The enterprise account
is outside this release setup.

1. Enroll the personal account in the Apple Developer Program.
2. Register `build.agora.astation` and the Keychain capability under that team.
   Create a **Developer ID** distribution provisioning profile for the app.
   It must authorize the app's Keychain group and signing certificate, permit
   distribution to all devices, have a valid expiration, and prohibit debugger
   access. Keep the same team and application identifier prefix across future
   releases; changing them can make existing protected items inaccessible.
3. Create **Developer ID Application** and **Developer ID Installer** identities,
   with their private keys. Export both identities to a password-protected
   `.p12` for the isolated CI keychain. Include the required intermediate
   certificates. An Apple Development identity is insufficient.
4. Create an App Store Connect API key authorized for notarization, with its
   key ID, issuer UUID and private `.p8` file. The `.p8` is downloaded once.
5. Configure these GitHub Actions repository secrets:

| Secret | Value |
| --- | --- |
| `ASTATION_SIGNING_TEAM_ID` | The intended personal developer Team ID |
| `ASTATION_APPLICATION_IDENTITY` | SHA-1 fingerprint of the Developer ID Application certificate |
| `ASTATION_INSTALLER_IDENTITY` | Full `Developer ID Installer: ... (TEAMID)` certificate name |
| `ASTATION_SIGNING_CERTIFICATES_BASE64` | Base64 of the exported `.p12` containing both identities |
| `ASTATION_SIGNING_CERTIFICATES_PASSWORD` | Password for the `.p12` |
| `ASTATION_PROVISIONING_PROFILE_BASE64` | Base64 of the Developer ID distribution profile |
| `ASTATION_NOTARY_PRIVATE_KEY_BASE64` | Base64 of the notarization API key's `.p8` |
| `ASTATION_NOTARY_KEY_ID` | The notarization API key ID |
| `ASTATION_NOTARY_ISSUER_ID` | The API issuer UUID |

Transfer credentials from their secure store directly into GitHub secrets.
Never put private keys, passwords or credential values in Git, docs, shared
memory, skills, or PR bodies. Secret names and signing setup status are safe
handoff information. Retain the originals securely for renewal and recovery.

## Rehearse before tagging

The Release workflow supports `workflow_dispatch` with a numeric `version`.
A rehearsal builds and tests the core, packages the app, signs nested code
and the app with the hardened runtime, validates its actual entitlements,
and runs a synthetic Data Protection Keychain probe using the release profile.
It notarizes and staples both the app and installer, checks Gatekeeper, and
uploads the packages and checksums as workflow artifacts. It publishes neither
a GitHub release nor Docker images.

The `--bundled-resources-check` command is available in Debug and Release builds
and exits before app startup, permissions, logging or relay connections. CI runs
the optimized executable's check and release packaging runs the signed app's
check from an unrelated directory; both enforce a 30-second timeout.

```sh
gh workflow run release.yml --ref main -f version=0.4.20
```

Download the rehearsal artifacts and verify on an Apple Silicon Mac running
macOS 14 or later. Check installation, relay connection, credentials
save/copy/update/delete, safety-code comparison and Touch ID, and Atem
unlock/migration with the current client. Recheck microphone, camera and
screen/system-audio permissions under the hardened runtime. Use an isolated
account for revocation/interruption tests. CI's Keychain probe verifies the
accessibility class and deletes its synthetic item; it does not replace real
Secure Enclave, Touch ID, media-permission or cross-machine checks.

The signing and notarization path cannot be verified with production credentials
until the paid account is available. Validator tests cover missing inputs,
wrong teams/certificates/groups, local-only and expired profiles, debugging
permissions, malformed metadata, version injection and credential-safe errors.

## Publish the verified commit

After the rehearsal and real-Mac checks pass, fetch current `main`, confirm its
CI result and review the exact commit. Ensure the version has not already been
released, then create and push only that release tag:

```sh
git fetch origin --tags
git tag -a v0.4.20 origin/main -m 'Astation v0.4.20'
git push origin v0.4.20
```

Tag publication is the release action. The workflow refuses missing signing
credentials before building or publishing. Local-device profiles, ad hoc or
wrong-team signatures, missing Keychain entitlements, failed notarization,
failed Gatekeeper checks and a failed packaged-app smoke test prevent upload.
Signing assets are owner-only temporary files; the temporary keychain is
deleted and the runner's prior keychain search list is restored on exit.

Docker images publish only after the signed macOS package passes. The GitHub
release publishes only if the app, change detection and required Docker builds
succeed. Native release tags are separate from the rolling relay/webapp
deployment triggered by a `main` merge.

Verify the final workflow, two macOS downloads and `.SHA256SUMS`, then record
the version, commit, validation and any remaining limitations in shared Atem
memory. The other agent owns Atem releases; coordinate through that memory.

For local-only builds, use [personal-team signing](atem-device-verification.md#personal-team-local-signing).
