# Credentials on This Mac

Open Astation Settings and select **Credentials**. This editor saves named API
keys, passwords, PEM text and JSON values in the protected Mac Keychain. Use a
provisioned Astation build; ad hoc or unsigned builds cannot access this store.
The Keychain item requires an unlocked Mac and is not synced through iCloud.

## Add and update

1. Click **Add Credential** and enter a name such as `OPENAI_API_KEY`.
2. Leave **Use project scope** unchecked for Global. For a project credential,
   check it and enter the Git remote or normalized key, such as
   `github.com/owner/repo`. HTTPS and `git@host:owner/repo.git` forms normalize
   to the same scope.
3. Paste the value. **Show multiline value** opens a text editor for PEM, JSON
   or multiline values. Values retain their exact whitespace and may contain
   up to 64 KiB of UTF-8 text.
4. Click **Save with Touch ID** and approve. The credential appears in the list
   only after the Keychain write succeeds.

Names match case-insensitively within a scope. Global `openai` and project
`openai` can have different values. To replace one, select its row and click
**Update**. The saved value is not displayed in the editor; enter a replacement.
The version increases after a successful save.

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
