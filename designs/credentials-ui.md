# Local Credentials Editor

Settings > Credentials manages named API keys and passwords on this Mac.
Each credential belongs to this Astation identity and either Global or a
normalized Git project. Names match case-insensitively within a scope; values
retain their exact whitespace and may contain up to 64 KiB of UTF-8 text.

The editor uses a separate Data Protection Keychain item with
WhenUnlockedThisDeviceOnly accessibility. It never writes secret values into
UserDefaults, files, logs, memory, skills, the shared-notes vault, SSO broadcasts,
or the relay. Keychain failures and unsupported/corrupt records retain the
existing item and fail closed. The existing SSO and E2EE identities are separate.

Add, update, delete and copy require Touch ID. The controller captures the
Astation's identity and record revision before asking for approval, and checks
that context again before acting. Cancelled or stale callbacks cannot change
data or copy a value. Leaving the tab or closing Settings cancels input sheets,
delete confirmations and authentication; late sheet results cannot start a new
approval. Updates use optimistic revision checks; a failed Keychain
write reports failure and leaves the previous record intact.

The list contains only metadata. Editing an existing credential starts with a
blank value rather than revealing its saved value. Input is masked by default
and is cleared when the editor closes. Explicit clipboard copies expire after
30 seconds; expiration clears only the clipboard version written by this app.

This editor is local storage. Atem's approved design in
Agora-Build/Atem/designs/e2e-encryption.md specifies a separate signed,
scope-encrypted credential service with manifests, grants and get/list commands.
That service is not implemented by the current client/relay. This UI must not
claim synchronization or Atem availability until that integration is built.
The local Keychain record is not that service's wire format and must not be
uploaded as-is. Memory encryption On/Off does not change these local credentials.

Validation covers actual protected Keychain round trips in a provisioned host,
account/scope isolation, case-insensitive names, opaque values and size bounds,
corrupt/newer records, failed writes, stale revisions, denied/stale approvals,
clipboard expiration, and UI input/selection behavior with synthetic values.
