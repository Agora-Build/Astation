# Atem and Astation session integration handoff

Updated 2026-10-16. The consolidated Astation work is in
[draft PR #50](https://github.com/Agora-Build/Astation/pull/50),
`feat/push-approvals`, against main. It includes the r6.2 client from the closed
PR #49 and the native r7 approval inbox. All Atem implementation belongs to the
Atem owner; no Atem checkout was modified or built for this integration.

The session base is [Atem #68](https://github.com/Agora-Build/Atem/pull/68),
tag `atem-session-v1-r6.2`, with no legacy fallback. The current runtime and
additive r7 approval contract are consolidated in
[Atem #72](https://github.com/Agora-Build/Atem/pull/72), `feat/session-runtime`.
Native approval integration pins the published contract at
`5ce333e505e77429ffbfd443bdb0794b45136a03`
([protocol](https://github.com/Agora-Build/Atem/blob/5ce333e505e77429ffbfd443bdb0794b45136a03/designs/protocol/atem-session-v1.md),
[host handoff](https://github.com/Agora-Build/Atem/blob/5ce333e505e77429ffbfd443bdb0794b45136a03/designs/protocol/atem-host-handoff.md)).
The later #72 commit `61b4b4b` changes PTY stop grace only, with no wire changes.

## Ready on Astation

- One authenticated session client per host connection serves Connections,
  terminal windows and the approval inbox. The registry supplies exact session,
  process, workspace, capability and activity data. Refresh sends session list,
  never agentListRequest or terminal list.
- Each new attachment resets sequence, registry, removals, terminal queues,
  pending replies and leases. Durable trust/runtime fences and submission
  recovery metadata survive. Reconnect queries receipts without replaying a
  command, approval answer or control acquisition.
- All requests bind the full target and attachment; mutations bind the lease.
  Terminal host events use verified connection, process, subscription and
  stream fencing. Removed operations have no outgoing fallback. Family errors,
  local takeover, deadline expiry and stale replies cannot restore authority.
- Claude structured prompts require chat-v1. Codex uses terminal input/paste.
  Browser access stays disabled, including before hello, pending the secure
  companion contract. No unbound chat is sent.
- Native r7 approval requests arrive independently of a lease. Allow once,
  Claude's exact offered Always allow rule and Deny use durable approval
  submissions with acquire:true. See the
  [approval lifecycle and remaining integration](push-approvals-handoff.md).
- Connections shows session handshake failures and allowlisted error codes.
  Pairing-code sockets transfer pairing credentials but never enter the online
  Atem list or become a session/control target.
- A hello refused as unauthorized before any accepted welcome may retry after
  verification or an explicit request, using a fresh id and the still-verified
  authenticated context. There is no timer retry. Stale hello replies are
  ignored. An already welcomed attachment must reconnect after failure.

## Local validation

The provisioned personal-team `Astation Local.app` runs from
`Astation/.build/Astation Local.app`, retaining bundle identifier
`build.agora.astation.local.xmgq79xmd5` and its protected Keychain access group.
Strict signature checks and bundled transcription/terminal resource checks
pass. The profile has no APNs entitlement; only offline push is disabled.

On 2026-10-16 at 19:56 local, the verified Genie link completes
`hello -> welcome -> list -> sessions`. Connections shows exactly one online
Atem, `relay:Genie`, with:

- Claude `ses-vozq7s7qkbvr`, Idle.
- Codex `ses-m636w7gytzwx`, activity Unknown as reported by the host.

The earlier 19:42 hello received an error before safety-code verification
finished. Its old logger hid the error code, so that specific refusal cannot
be identified retrospectively. A fresh authenticated connection after
verification succeeds. The spurious `relay:TZAZ-Y9W6` row came from Astation
adding its own pairing transport as an online Atem, rather than evidence of a
second Atem runtime socket.

There are 119 passing focused tests. The full Swift suite executes 879 tests,
11 environment-dependent skips, zero failures. The skips cover provisioned
XCTest/Keychain, live capture and optional local model integrations; they do
not represent a live APNs or agent-approval test. No agent command or approval
decision was sent during this live discovery check.

Production is unchanged: health reports main `9245603`, two replicas and Redis
OK. Relay account registration still refuses the Agora verifier configuration
(`AGORA_ACCOUNT_USERINFO_URL` / `AGORA_ACCOUNT_SUBJECT_FIELD` absent). That is a
separate account-discovery gate; the saved paired Genie connection works.

## Joint tests remaining

1. Use the same #72 runtime for pair/verify/launch, preserving existing
   sessions. Open, close and reopen Connections and terminal windows; confirm
   no second hello is sent after a welcome on the same attachment.
2. View each session, then explicitly take control to type/resize/paste and
   release. Host local input must revoke queued remote writes. Expiry and late
   renewal must not restore control. No legacy control op or lease_id is sent.
3. Submit a Claude prompt and observe its durable receipts. Test interrupt and
   stop separately. Disconnect immediately after acceptance; reconnect queries
   the original receipt without another dispatch or a restored lease.
4. Trigger real Claude and Codex approval hooks with no lease holder. Check
   in-app alert/inbox, exact Claude rule confirmation, atomic answers, terminal
   answers, expiry, duplicate catch-up and delayed receipts. Disconnect or
   revoke while a request is pending; stale cards must be disabled.
5. Reauthenticate/reconnect to the same runtime, then restart the runtime.
   Registry sequence can restart, but runtime rollback and old process/stream
   frames remain refused. Exercise busy/stale-target/family error fixtures.
6. Unpair/revoke and pair/verify again. Old authority never returns. Local
   agents, memory, vaults and saved credentials remain intact.

The actual host currently supports one native Astation link; multi-attachment
core harness coverage does not establish simultaneous live controllers.

## Trust and offline delivery gates

Section 9 remains the gate for resume, browser/QR grants, account-wide native
access, signed membership/revocation ordering, freshness proofs and live
traffic E2EE. The relay is never identity, encryption-state or control
authority. Compatibility mode does not claim relay confidentiality.

Offline push needs an eligible push-enabled Apple profile and APNs provider
credentials, authenticated Atem-to-relay device proof, authorized recipients
and a durable, revocation-aware dispatch outbox. Current room ids and SSO/data
account grouping cannot supply that authority. The native inbox and transport
adapters do not imply live APNs delivery. See
[provider setup](../../docs/push-notifications.md).

Use this hosted handoff for cross-machine coordination. The latest local Atem
memory is `mem_752f0f044652415c9a475fe99cde7d29`; the relay rejected its sync
with `memory does not match the account encryption mode`. Do not assume the
shared store contains this update unless sync succeeds.
No production merge or deployment is included.
