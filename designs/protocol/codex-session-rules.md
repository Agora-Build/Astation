# Codex approval session rules

Source: Atem main `976e15462b834a0fc270a9b541cd6952632c522c`,
[agent chat API](https://github.com/Agora-Build/Atem/blob/976e15462b834a0fc270a9b541cd6952632c522c/designs/agent-chat-api.md)
and [session contract](https://github.com/Agora-Build/Atem/blob/976e15462b834a0fc270a9b541cd6952632c522c/designs/protocol/atem-session-v1.md).

## Grant and display

The authenticated session approval request supplies `always_rules`. Astation
offers Always allow for both Claude and Codex, only when a rule was offered.
Confirmation shows the exact label, scope, host and session. Codex session
rules explain that they cover one agent process and the exact command/cwd.
The answer uses `kind: "approval"`, `decision: "allow_always"`, the offered
`rule_id`, and `acquire: true`. The full current approval snapshot must still
match when the user confirms. The host atomically acquires control and answers.

`approval_rules` is the authoritative whole list for a session/process. Lists
are accepted only from the current verified connection and attachment, after a
registry snapshot, with control permission and a matching running process.
At most 32 unique, validated rules with session scope are accepted. A fresh
registry snapshot clears prior rules before the host's catch-up lists arrive.
Process replacement/end, lost authorization, reconnect and trust changes fence
cached rules and actions. No relay label or push hint supplies authority.

## Automatically allowed activity

The native session client maintains one read-only chat view per running,
chat-capable process (at most 64 per host, sorted by session ID). These views
are shared by the approval UI and local API. Each open carries the full target
and attachment binding. It never takes a control lease or submits a prompt.
The hub captures authenticated connection context before asynchronous dispatch
and rechecks it on delivery. The observer also checks route, conversation ID,
process generation, sequence, message shape and size before retaining a card.

Only `auto_allowed` approval parts appear in the activity section. They never
populate the pending inbox, trigger an approval alert or offer answer buttons.
Whole-message updates replace earlier cards with the same ID. Repeats are
ignored; a gap closes that observation until an explicit session refresh.
There is no automatic reopen loop for truncated history. The observer retains
at most 64 recent cards per host; the inbox shows at most 128 overall. It reads
the latest host history page (up to 50 messages), not unlimited audit history.
Refresh/reconnect opens new conversation IDs so delayed old events cannot apply.
Browser companion access stays behind its existing security gate.

## Revoke and recovery

The rules list offers Revoke followed by one confirmation showing the exact
rule, host and session. Revocation sends `kind: "approval_rule_revoke"` and
exactly `payload: {"rule_id": "..."}` with the current target and attachment,
omitting `lease_epoch`. r7.3 requires current control permission, the running
process and an active rule, without requiring a held lease. Revoke never
acquires, releases, renews or transfers control, including when another client
holds it. No acquire field is permitted in the payload. A stale confirmation
cannot revoke a changed rule or process.

Rule cards publish immutable presentation snapshots for rule availability and
revocation receipt state. Actions and local API availability still check the
live session authority after confirmation, rather than trusting a displayed
snapshot. There is no fallback that acquires control when an older host refuses
the lease-free operation.

The existing durable submission journal saves target, request UUID, kind and
payload digest before sending. It stores neither command text nor the rule's
label. Uncertain delivery only queries the original receipt after reconnect;
Astation never resends the mutation or restores control automatically. Pending
and unknown outcomes disable another revoke. Completed receipt and the host's
rule list establish completion; a later authoritative regrant of the same rule
ID is usable again. The local API provides identical semantics and rejects UUID
reuse with different content. See [API routes](../../docs/local-control-api.md).

## Validation

`AtemSessionRuleTests`, approval tests and local API tests cover Codex grants,
exact rule selection, list bounds, wrong route/process/permissions, refresh and
process-end clearing, lease-free revocation with control permission, unchanged
operator/lease state, expired leases, stale device/attachment/process authority,
disk failures, durable
recovery, duplicate UUIDs, revoke/regrant, and automatic cards with no alert or
answer authority. Chat tests cover stale conversations, generations, sequence
gaps/repeats and malformed parts. Existing Claude approval behavior is retained.

The r7.3 shared revoke fixture is pinned with SHA-256 in
`Tests/AstationTests/Fixtures/atem-session-v1`. The client test verifies the
published bytes, decodes valid client requests and rejects the fixture's
invalid acquire payload. Host dispatch, command
matching and worker revocation belong to Atem's fixture harness and live joint
tests; decoding the fixture does not establish those effects.

Build and test with the provisioned local test host:

```sh
bash scripts/verify-local-signing.sh XMGQ79XMD5
```

Live grant / exact-match auto-allow / revoke verification still requires an
isolated real Codex session with approval hooks. Use the matrix in the local API
documentation and check both durable receipts and the actual agent behavior.

Historical verification, 2026-10-17 11:56 PDT, before r7.3: the personally
provisioned app passed 922 tests
(6 skipped, zero failures), plus signature, Keychain group, bundled-resource and
executable-checksum checks. The canonical `Astation Local.app` was replaced and
launched. Genie reconnected with running Claude and Codex sessions, neither
holding a remote control lease. The r7.2 status, rules and activity API reads
succeeded; the read-only smoke check found one Codex session rule and three
`auto_allowed` activity cards. Revoke was correctly unavailable without control.
No prompts, approval answers or revocations were sent to those working sessions;
this does not establish the live grant/revoke lifecycle. The personal-team
provisioning profile expires on 2026-10-24 at 02:29:04 UTC.

Historical verification, 2026-10-18 09:01 PDT: the r7.3 personally provisioned
build executed 924 tests (6 skipped, zero failures), including 15 targeted
session-rule tests. Signature, personal-team Keychain group, bundled-resource
and executable-checksum checks passed. The canonical app was replaced and
relaunched at `/Users/brent/Dev/Agora.Build/Astation/.build/Astation Local.app`.
Its executable SHA-256 is
`202b3fe1fe0dbc018c63c859a3a76e7f9d29d6312d86165280b4938b9c392b20`.
The read-only local API smoke check reported r7.3 and lease-free revocation;
Claude and Codex were running with no remote control held. It found zero
active rules and three auto-allowed activity cards. No prompts, revocations
or approval answers were sent, so the live rule lifecycle remains unverified.

The current client requires r8 at Atem main
`4f87bab1289848cb6a0da5707d2e7830eb5c057d`. Answers and revocations require
control permission and do not acquire, renew or replace the lease. See the
[r8 lifecycle](r9-client.md) and [local API guide](../../docs/local-control-api.md).
The earlier live observations do not establish a complete live rule cycle;
that remains a joint provider test.
