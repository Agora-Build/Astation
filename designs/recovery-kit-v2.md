# Recovery Kit v2

The account recovery format follows the accepted r9 contract. The user-facing
name of `kit_tag` is **Recovery Kit Integrity Check**: it confirms that the
recovery secret, account and original trust record belong together. The shared
`atem-client` implementation owns its derivation, validation, backup opening and
recovery signatures. Native code supplies presentation, protected persistence,
owner authentication and transport; it does not implement another recovery
cryptosystem.

## Export and Import

The text begins with `Astation Recovery Kit v2`, followed by exactly one each
of Account ID, Relay, Recovery Secret, Genesis Fingerprint and Recovery Kit
Integrity Check. The secret and integrity check use canonical unpadded
base64url; the genesis fingerprint is 64 lowercase hexadecimal characters.
Unknown, duplicated, missing or malformed fields are refused. Import checks
the integrity check before any network request or local account change. A v2
kit must never fall through to the old Astation-ID-only restore path.

The fingerprint is an independent offline trust anchor. A relay-supplied
device list must verify from that fingerprint before any host, manager or
backup from it is used. The integrity check detects mixed or altered fields;
it does not make a relay-selected genesis authoritative. The relay URL is a
routing hint, not a signed identity or part of the integrity check. Import uses
the user's configured relay for authenticated requests; it never sends the
account token to a URL supplied by the pasted kit.

## Setup and Interrupted Operations

Generate the recovery secret and prepare the genesis body in protected
storage before requesting fresh owner confirmation of that exact body. Store
the exact signature before sending the genesis. A network retry sends the
same stored bytes. Export is available only after relay publication and the
local committed-genesis checkpoint both succeed. Saving the kit is a separate
durable acknowledgment bound to that genesis; an old kit's acknowledgment
does not satisfy it. An uncertain local write halts the instance until its
protected checkpoint is reloaded and reconciled. Another operation must not
replace a saved pending setup.

## Restore

Use the shared `RestoreSession` state machine. After kit validation, fetch the
anchored log and its newest committed K backup and obtain a fresh signed head
from at least one host in that verified log. No host reachable means waiting
and retrying, with no replacement identity, current K, or enrollment written.
Refuse substituted genesis, retired kits, stale or damaged backups and logs
behind a host. Never create a replacement trust root to make recovery pass.

Store the recovered current/retained K set durably before preparing enrollment.
Persist the exact `recovery_add` before sending it; after a restart, confirm
the head again before resending it. A CAS conflict requires the shared
verifier and a new freshness/backup check before another enrollment is built.
Recovery is pending until approved by another manager or its 24-hour wait
completes. It grants no permission to bypass a freeze, rotate K or publish a
backup early. The kit secret is never sent to the relay or a host.

## Pairing Safety Code v2

The host channel key is required in the reveal and commitment. The account
genesis fingerprint is required in `verifyKeys` and the v2 safety digest.
Both fields are immutable for an attempt, along with the captured host trust
generation and authenticated route/account. Reconnection, account change,
expiry or changed keys invalidates pending owner confirmation. Missing v2
fields are refused; there is no fallback to the old safety digest. A final
`deviceVerified` also needs the relay-committed signed membership through the
exact host key/id/generation. The safety-code update alone cannot enable r9
admission.

## Relay Storage Transport

The relay's account login controls visibility and resource use only. It does
not enroll a member or establish a trust root. Native clients retain their
own genesis pin and verify every entry, backup and host response with the
shared core. A restored device must sign in to the same account as the kit's
creator before reading its encrypted recovery records; login alone cannot
decrypt them or grant access to a host.

The storage routes use the existing verified account access token over HTTPS.
The relay records that verified subject when it creates a log. It refuses a
different subject before returning any record. A client supplies the genesis
hash explicitly; there is no relay-selected "current root" to trust. A new
genesis also requires that its creator is already registered to that verified
subject and data account. This prevents copying someone else's public genesis
to claim storage ownership. The valid genesis self-signature is still required.
Subsequent appends use the agreed signed-entry CAS. Only genesis may use the
empty-chain CAS sentinel `{seq:0, hash:<64 zeroes>}`. Neither an access token nor an account label can
replace that signature or authorize a device to a host.

The log routes retain the pinned R9.4 shape. Backup storage uses
`PUT /api/remote/v1/logs/{genesis_hash}/backups/{blob_version}` with the exact
canonical envelope as the body and the already signed `k_backup` entry in an
`X-Astation-Backup-Entry` base64url header. The entry is proof of a current
manager's intent to upload these exact account/root/version/kit/kids/hash
bytes, not a log append. Its signature and historical predecessor verify,
and the signer must still be an active manager at the current stored head.
An unrelated CAS loss can therefore retain the uploaded envelope. A replay
can only upload the same envelope; it cannot advance a log or rotate K.
The relay's convenience verifier and account metadata remain nonauthoritative.

`GET` of the same URL returns the envelope only if a committed `k_backup`
entry names it. Clients fetch exactly the version named by their verified
chain, never an occupied version or a relay-advertised maximum. Upload is
put-if-absent with exact-byte retries and `409 {max_occupied}`. The relay
retains the two newest committed backups per recovery key and collects
uncommitted uploads after an hour. Storage changes are one database transaction
per root and work across replicas. Memory-only storage is limited to tests.

`POST /api/remote/v1/logs/{genesis_hash}/probes/{host_id}` accepts only an
R9.7 `init` frame and returns one public `accept`. Account login and root
ownership gate this bounded recovery-only transport. The signed `add_host`
signer's former relay room supplies a routing hint, including when that Mac
is offline. The relay assigns a fresh `rp_` channel handle, sends `open` then
`init` on the host's current outbound link, and closes it after the response
or ten seconds. It never sends `finish`, `rec`, commands or a client identity.
Replies are bound to the captured host socket generation; the native shared
core independently verifies the fresh challenge, host signature and head.
Cross-replica replies use the relay bus. Pending requests are bounded and
discarded on interruption; retries create a new challenge and handle.
This endpoint cannot authenticate a controller or enable session admission.

## Key Changes and Replacement Devices

Rotation and AEK1 import checkpoint the proposed K before any use, publish its
backup together with retained keys, then install it. An interrupted upload
resends the same sealed bytes and signature. The previous K remains current
until backup commitment. Encryption mode still changes through the existing
validated migration lifecycle; a backup never sets encryption ON. Repeated kit
export checks the committed backup against the actual key set and avoids
another signature/upload when nothing changed.

A failed local key installation retains the pending key and committed backup.
After restart, verify and open that exact backup before retrying installation;
do not generate another key or ask for another backup signature. An uncertain
final checkpoint halts the current coordinator until its protected state is
reloaded. If a CAS conflict reveals that the signing manager was removed,
stop before requesting another owner confirmation or signature. An unrelated
head change requires owner confirmation of the new exact backup body.

A recovered device keeps the imported kit and original root. Export remains
available after fresh restore verification; pairing and manager writes require
the active replacement's exact auth/encryption keys and manager role. A pending,
vetoed, removed or substituted device gains nothing. Signed manager approval
is refreshed from the chain before pairing. The original native device ID and
keys are never replaced by the kit.

## Current Validation and Remaining Gates

Tests exercise strict format/integrity and v2 known answers, exact retries,
owner/save cancellation, uncertain writes, stale routes/accounts, interrupted
backups, rotation, fresh host challenges, pending replacement rejection and
signed manager approval after restart. Real provisioned tests use disposable
test identities to verify the Data Protection Keychain/process lock and an
Enclave-signed genesis. Postgres tests cover multi-replica CAS, rollback and
restart. HTTP/WebSocket tests cover genesis retry/isolation and a recovery probe
with the original Mac offline. No live account keys/floors are reset.

Practical coordinator regressions also cover Keychain-install failure after
relay commitment, an uncertain checkpoint after installation, lost rotation
commit replies, overlapping setup while owner confirmation is open, a competing
manager's CAS update, manager removal during confirmation, and a lost recovery
enrollment reply followed by restart. They use the shared cryptography and
membership implementation, with injected local/network failures; they do not
stand in for a live UI ceremony.

The accepted Apple binding does not expose durable membership-state export/load
for recovery wait records and wait-ended decisions. In-process snapshots retain
state; reconstruction from signed entries after restart conservatively restarts
pending waits. Automatic 24-hour activation across restart is therefore not
complete. The requested shared binding API is tracked on
[Atem #93](https://github.com/Agora-Build/Atem/issues/93).
Do not substitute a Swift timer, trust relay time, or grant access early.

The iOS Simulator source target compiles; execution is blocked by the local
CoreSimulator version mismatch. Rendered owner-auth UI, a live host ceremony,
independent native/mobile/service admission and sealed push/provider integration
still need their platform/conformance gates. Independent remote admission stays
disabled and Atem #89 stays unmerged pending the ceremony gate. This worktree
does not deploy the relay; local provisioned build verification is a separate
step from the live ceremony and independent-admission gates.
