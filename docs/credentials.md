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
4. Click **Save with Touch ID** and approve. The credential appears in the list
   only after the Keychain write succeeds.

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

Project names are encrypted to the verified Astation even when memory encryption
is off. They are suggestions, not device permissions. See the
[discovery protocol](../designs/credential-project-discovery.md) for trust and
revocation rules. Credential values remain local to this Mac.

## Copy and delete

Select a row and click **Copy Value**, then approve Touch ID. The clipboard
clears after 30 seconds or app termination, provided it still contains that
copy. A later clipboard change is retained.

Select **Delete**, confirm and approve Touch ID to remove the saved credential.
Cancelling or failing authentication changes nothing. If another operation
changes the store while a prompt is pending, the stale operation is refused;
refresh and reopen the editor. Storage errors retain existing credentials.

## Availability and boundaries

These credentials are available on this Mac. Atem currently implements device
verification, key unlock/status and memory encryption, but not the designed
`atem cred get/list` service. This editor does not publish credentials to the
relay or to Atem. Building that integration requires the signed scope directory,
manifests, per-device scope grants and read commands described in Atem's
`designs/e2e-encryption.md`. The shared-notes vault is separate.

The editor's store is separate from Agora account sign-in and from account-data
encryption. Turning memory encryption on or off does not change its contents
or Keychain protection. Save secrets in this editor rather than memory, skills,
instruction files or shared notes. Credential synchronization and identity
recovery for this local store remain separate work.

## Local build and validation

Quit the running Local.app, then in its worktree run:

```sh
bash scripts/verify-local-signing.sh XMGQ79XMD5
open "/Users/brent/Dev/Agora.Build/Astation-e2e-verification/.build/Astation Local.app"
```

The signing helper uses the existing Personal Team and retains Keychain access.
It never uses the organization/enterprise team. Automated tests use synthetic
credentials and remove their temporary Keychain item. No real credential is
needed for testing.

See [the lifecycle and storage design](../designs/credentials-ui.md) for
authorization and persistence invariants.
