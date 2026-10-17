# Credentials on This Mac

Open Astation Settings and select **Credentials**. This editor saves named API
keys, passwords, PEM text and JSON values in the protected Mac Keychain. Use a
provisioned Astation build; ad hoc or unsigned builds cannot access this store.
The Keychain item requires an unlocked Mac and is not synced through iCloud.

## Add and update

1. Click **Add Credential** and enter a name such as `OPENAI_API_KEY`.
2. Leave **Use project scope** unchecked for Global. For a project credential,
   check it and choose a project from the editable list, or enter the Git remote or normalized key, such as
   `github.com/owner/repo`. HTTPS and `git@host:owner/repo.git` forms normalize
   to the same scope.
3. Paste the value. **Show multiline value** opens a text editor for PEM, JSON
   or multiline values. Values retain their exact whitespace and may contain
   up to 64 KiB of UTF-8 text.
4. Click **Save Securely** and approve with Touch ID or your Mac login password.
   The credential appears in the list only after the Keychain write succeeds.

Project spelling is retained for display and saving: `github.com/Agora-Build/Atem`
stays capitalized. Project comparisons and credential names are case-insensitive,
so case variants share one scope and appear once in suggestions. Existing
lowercase records remain readable; their original spelling can only be restored
when a Git remote or a manually entered spelling supplies it.

Names match case-insensitively within a scope. Global `openai` and project
`openai` can have different values. To replace one, select its row and click
**Update**. The saved value is not displayed in the editor; enter a replacement.
The version increases after a successful save.

## Project suggestions from Atem

The project list combines repositories reported by verified Atem devices with
scopes already used by saved credentials. You can always type another Git remote
to add a credential for a project that is not listed; no connected Atem is needed.

### Pair and report from another machine

1. On the Mac, run a current, provisioned Astation build, sign in, and confirm
   its account/relay connection is available.
2. On the Linux machine or other Mac, run `atem pair`. Use `atem pair --save`
   if shared sign-in credentials should remain usable after Astation disconnects;
   without saving, they have a five-minute grace period after disconnection.
3. Approve pairing in Astation and compare the complete safety codes. Type `y`
   in Atem; on the Mac click **Codes Match**, then use Touch ID in that window
   or click **Use Mac Password...** for macOS authentication.
   Either side can finish first. Save and confirm the complete recovery kit
   if requested, and finish any key-escrow/unlock approval.
4. Check `atem status`: the device must be verified, and its key agent
   must be unlocked before reporting projects. **Connected** or **Paired with
   Astation** alone does not establish either state.
5. In the Git repository on the Atem machine, run:

   ```sh
   atem cred unlock
   atem cred projects
   ```

Unlock approval happens on the home Astation Mac, even when Atem runs on Linux.
Keep the command open while approving on the Mac; the wait is bounded to five
minutes. Saving shared sign-in does not unlock device keys indefinitely.
Open Settings > Credentials on the Mac, click **Add Credential**, enable
**Use project scope**, and select the repository. Use **Refresh** if needed.

### Client and key-agent versions

Use the updated Atem build with an unlocked key agent. Atem reports its current
Git repository and the projects it has remembered for this account when it
connects. Astation also requests an update when opening Credentials, opening an
editor or clicking Refresh. New suggestions do not replace the project or value
you are editing. A repo with no usable Git remote is not a project scope.

Older builds may report lowercase project names or lack reporting entirely.
After updating, run `atem cred lock` and `atem cred unlock` with the updated
binary to replace an older unlocked key agent, then run `atem cred projects`
in your repository or use the Atem TUI. The lock command wipes keys and stops
the agent; unlock starts the updated agent and asks this Mac for approval.
An older unlocked agent is never replaced automatically. Reporting does
not prompt for Touch ID or unlock keys automatically. Accepted suggestions can
remain available after a short-lived CLI disconnects, until Astation quits;
saved scopes remain available after relaunch.

Check `atem --version` and `atem cred --help` on the Atem machine. GitHub `main`
can be newer than the latest release; the npm package downloads the binary for
its published version. If a command is missing, install a release containing it
or build current `main` using the [Atem source instructions](https://github.com/Agora-Build/Atem#build-from-source).
Run the source binary explicitly, such as `./target/release/atem`, for every
upgrade command; building alone does not replace a global npm installation.
`atem status` marks an older running agent as **older build**.

Project names are encrypted to the verified Astation even when memory encryption
is off. They are suggestions, not device permissions. See the
[discovery protocol](../designs/credential-project-discovery.md) for trust and
revocation rules. Credential values remain local to this Mac.

## Complete an encryption migration

Settings > Security > End-to-End Encryption controls the signed account state.
While **Turning on** or **Turning off** is displayed, use a current, verified
Atem and run `atem cred unlock` on its machine. This reconnects an already
unlocked device to finish a pending migration; `atem sync` alone only talks to
the relay. If interrupted, run the unlock command again.

Zero plaintext or obsolete fields are progress counts, not confirmation that
encryption is On. Atem verifies migrated content before sending a signed
completion. Astation captures the authenticated context, journals accepted
completion and durably commits the final state after checking current device
trust and cryptographic prerequisites. Atem can then disconnect; retries and
duplicate reports are safe. Confirm the final **On** or **Off** state on the Mac.
See the [migration lifecycle](../designs/e2e-encryption.md).

The relay is transport/storage, not the authority for device identity or
encryption state. With encryption on, shared memory, skills and vault content
are encrypted before reaching it, while routing identifiers, timestamps and
ciphertext sizes remain visible. Migration cannot prove erasure of old
plaintext backups. Turning encryption off migrates shared content to plaintext;
it does not alter this Mac's credential store. Atem's local `knowledge.db`
remains plaintext with mode 0600.

## Copy and delete

Select a row and click **Copy Value**, then approve with Touch ID or your Mac
login password. The clipboard clears after 30 seconds or app termination,
provided it still contains that copy. A later clipboard change is retained.

Select **Delete**, confirm and authenticate with Touch ID or your Mac login
password to remove the saved credential.
Cancelling or failing authentication changes nothing. If another operation
changes the store while a prompt is pending, the stale operation is refused;
refresh and reopen the editor. Storage errors retain existing credentials.

## Availability and boundaries

These credentials are available on this Mac. Atem currently implements device
verification, key unlock/status and memory encryption, but not the designed
`atem cred get/list` service. This editor does not publish credentials to the
relay or to Atem. Building that integration requires the signed scope directory,
manifests, per-device scope grants and read commands described in Atem's
[encryption design](https://github.com/Agora-Build/Atem/blob/main/designs/e2e-encryption.md).
The shared-notes vault is separate.

The editor's store is separate from Agora account sign-in and from account-data
encryption. Turning memory encryption on or off does not change its contents
or Keychain protection. Save secrets in this editor rather than memory, skills,
instruction files or shared notes. Credential synchronization and identity
recovery for this local store remain separate work.

## Local build and validation

Use full Xcode with your personal account signed in and an Apple Development
certificate for your Personal Team. Keep the same team and bundle identity when
updating an existing installation so it retains access to its Keychain items.
Quit the running Local.app, then in its worktree run:

```sh
PERSONAL_TEAM_ID="YOUR_10_CHARACTER_TEAM_ID"
bash scripts/run-dev.sh --build-only
bash scripts/verify-local-signing.sh "$PERSONAL_TEAM_ID"
open ".build/Astation Local.app"
```

Replace the placeholder with your Personal Team ID. The signing helper uses
only that team and packages `build.agora.astation.local.<lowercase-team-id>`;
it does not select an organization/enterprise team automatically. See
[personal-team signing](atem-device-verification.md#personal-team-local-signing)
for provisioning, profile renewal and signing checks. Automated tests use synthetic
credentials and remove their temporary Keychain item. No real credential is
needed for testing.

See [the lifecycle and storage design](../designs/credentials-ui.md) for
authorization and persistence invariants, and the
[Atem user guide](https://github.com/Agora-Build/Atem/blob/main/docs/credentials.md)
for its pairing, upgrade and migration workflow.
