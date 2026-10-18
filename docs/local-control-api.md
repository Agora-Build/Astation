# Local session, chat and approval API

The optional local API operates agents launched by `atem agent launch` using
the running native Astation's verified session, shared chat coordinator,
approval inbox and durable request journal. It requires Atem session r8,
pinned to Atem main `4f87bab1289848cb6a0da5707d2e7830eb5c057d` (PR #78).
There is no fallback to an older protocol. An incompatible Atem is hidden
from the session list; status reports `atem_upgrade_required: "true"`.
Upgrade Atem and reconnect it.

The API does not enroll devices or bypass verification, permissions, full
target/attachment/process checks or control leases. The relay transports
messages and is never an authority for identity or encryption state.
See [r8 lifecycle and security invariants](../designs/protocol/r8-client.md).

## Enable locally

Create a private random key file once, outside git and shared file hosting.
This example never prints the key:

```sh
python3 - <<'PY'
from pathlib import Path
import os, secrets
p = Path.home() / 'Library/Application Support/Astation/local-api-token'
p.parent.mkdir(parents=True, exist_ok=True)
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(secrets.token_hex(32) + '\n')
PY
```

Quit the old app and open the provisioned bundle with the opt-in:

```sh
open --env "ASTATION_LOCAL_API_TOKEN_FILE=$HOME/Library/Application Support/Astation/local-api-token" \
  '/Users/brent/Dev/Agora.Build/Astation/.build/Astation Local.app'
```

The file must be a same-user regular file, mode 0600, with one hard link;
symlinks are rejected. It contains 64 lowercase hexadecimal characters and
an optional final newline. The app loads it at startup. Quit/relaunch to
rotate it or disable the API; launching without the environment variable
leaves the routes disabled. Never share the token with a web page, put it in
argv, or publish it in docs/memory. It grants local session control to
processes that can read it.

Requests use port 8080 and require the actual peer to be loopback, exactly
one matching Authorization: Bearer header, and no Origin. Forwarded addresses
are ignored. No CORS, caching or redirects are supported. POST requires
Content-Type: application/json, at most 64 KiB, no duplicate JSON keys, and
protocol-safe integers. Responses close the HTTP connection. Keys and request
bodies are excluded from network debug logs.

## Routes

The helper reads the key from its protected file and does not invoke curl:

```sh
export ASTATION_LOCAL_API_TOKEN_FILE="$HOME/Library/Application Support/Astation/local-api-token"
python3 scripts/astation-api.py status
python3 scripts/astation-api.py sessions
python3 scripts/astation-api.py approvals
python3 scripts/astation-api.py approval-rules
python3 scripts/astation-api.py approval-activity
python3 scripts/astation-api.py post chat/read --file /private/path/read.json
```

| Route | Input or output |
| --- | --- |
| GET /api/v1/status | r8 implementation, lease-free answers/revocation, atomic Send, history polling, explicit API renewal, upgrade requirement and trust/push gates. |
| GET /api/v1/sessions | client_id, current descriptor, full target, phase/status, negotiated features, controls and control_owner. Target may be absent while connecting. Unsupported hosts are excluded. |
| GET /api/v1/approvals | Exact request, full target, client_id, provider/host, can_answer, status and authoritative resolution. |
| GET /api/v1/approval-rules | Active rules with client_id, target, exact rule, provider/host, can_revoke and status. Requires control permission, without a held lease. |
| GET /api/v1/approval-activity | Bounded informational auto_allowed cards, with client_id, target, message_id, created_at in Unix milliseconds and approval part. These never become pending alerts. |
| POST /api/v1/sessions/acquire | client_id, target, optional operator_id and takeover (default false). 202 means requested, not granted. |
| POST /api/v1/sessions/renew | client_id, target and matching operator_id. Renew every five seconds while operating. 409 if expired, not owned or already awaiting renewal. |
| POST /api/v1/sessions/release | client_id, target and matching operator_id. Releases that local caller's control and fences late acquisition replies. |
| POST /api/v1/sessions/submit | client_id, target, request_id UUID, kind prompt/interrupt/stop, text for prompt, optional operator_id. Prompt Send acquires atomically when unowned. Interrupt/stop require an already-held lease. |
| POST /api/v1/receipts/query | target and request_id. Returns durable local metadata and latest authenticated receipt/refusal. An absent receipt is unconfirmed. |
| POST /api/v1/chat/read | client_id and target. Opens/reuses the shared read-only view and returns a bounded snapshot, explicit loaded/closed/error state, sequence, messages and coverage. |
| POST /api/v1/chat/history | client_id, target and exactly one before/next/turn_id/request_id selector. 202 returns page_id; no control acquisition. |
| POST /api/v1/chat/page | client_id, target and page_id. Returns pending/error or the bounded completed page with ordered messages, sequence and retention coverage. |
| POST /api/v1/approvals/answer | client_id, target, request_id UUID, exact approval, decision allow_once/allow_always/deny, exact offered rule for allow_always, optional denial message. Lease-free. |
| POST /api/v1/approval-rules/revoke | client_id, target, request_id UUID and active rule_id. Requires control permission and the exact process, without acquisition or a lease transfer. |

A full target contains account_id, atem_device_id, host_trust_gen, session_id
and process_gen. Copy it from the current session list. A hostname, label or
session ID alone cannot identify an authority boundary. `operator_id` is an
opaque local ownership label, not a separate authentication principal; all
callers still require the bearer token. Omission uses `api:local-api`. Use a
stable distinct ID for independent scripts; the returned control_owner has
an `api:` prefix. Native terminal control has owner `native`.

## Send, control and recovery

An ordinary prompt atomically acquires an unowned host session. When another
controller holds it, the durable local record exposes refusal code lease_held
and its controller. After explicit user confirmation, repeat the same UUID,
text and target with `takeover: true` and `expected_controller` copied from
that refusal:

```json
{
  "takeover": true,
  "expected_controller": {
    "controller_session": "99999999-9999-4999-8999-999999999999",
    "lease_epoch": 7
  }
}
```

These fields supplement the original submit body. A stale local confirmation
returns 409; the host rechecks ownership at admission too. No ordinary retry
or receipt query acquires or executes again. A lease held by native UI or
another local operator cannot be consumed by this caller.

Poll sessions to confirm ownership, renew every five seconds and release
when finished. Astation never auto-renews API control. An abandoned caller
loses it within 15 seconds. Raw remote-terminal input, paste, resize, interrupt
and stop continue to require explicit held control.

HTTP 202 means journaled locally, not delivered, accepted or executed. Keep
the UUID and poll receipts for accepted/executing/completed/rejected or
outcome_unknown. An identical POST returns the existing identity; changing
its target/kind/payload returns 409. Only an explicit takeover following a
definitive lease_held refusal resends that same UUID. A definitive busy means
refused; a deliberate new attempt needs a new UUID. Uncertain outcomes require
checking the agent, without replaying the prompt or approval.

A completed prompt may include result with turn/user IDs, up to 32 reply IDs,
more and replies coverage. Read chat or page history by the original request_id
to obtain retained replies. Partial/unavailable content or absent result is
not execution failure and never permits resubmission. The journal stores no
prompt/transcript and is bounded to 4096 records/4 MiB; old final metadata
may be evicted. Connection loss queries existing receipts and never restores
control automatically.

## Chat and approvals

Chat opens without before/generation and becomes loaded only at history_end.
Whole-message updates share the ordered stream with history pages. A timeout
is unconfirmed, not empty completed history. Coverage, oldest_retained,
truncated, holes and locally_truncated describe retention; they never cause
reopen loops. Each history page is bounded to 50 messages, 256 KiB content and
1 MiB wire data, including its boundary. Page results are kept in memory,
at most four per view; clients should consume them promptly. Snapshots return
at most 50 messages/900 KiB of message data; the coordinator retains at most
eight views of 500 messages/8 MiB each. Reading another target prioritizes its
subscription within that bounded pool.

For an approval, copy the entire authenticated request unchanged. Always allow
echoes the exact rule ID, label and scope offered for Claude or Codex. An
unoffered rule cannot be invented. Denial messages are at most 512 UTF-8 bytes.
Closed/unavailable cards return 409. Answers omit acquire and lease_epoch;
they do not change the terminal controller or its deadline. Revocation also
leaves the lease unchanged. Poll the receipt and authoritative rules list to
confirm removal. Rule matching is implemented only by Atem.

The implemented interface supports polling chat, approvals, rule activity,
receipts and status without mobile clients. SSE replay, a full native chat
view and offline APNs delivery are separate work in the
[joint API proposal](../designs/protocol/agent-control-api.md). In-app approval
notifications continue to use authenticated catch-up. Push requires its own
provisioning, provider credentials and delivery verification.

## Verification

Automated tests run all seven pinned upstream client scenarios and native/API
integration cases: r8 negotiation, incompatible-host filtering, Send/takeover,
lease ownership/renewal/expiry, release before late receipts, lease-free
approval races, result projection, ordered history, null recovered predecessors,
coverage, stale contexts, strict JSON and HTTP admission.

Live mutation tests use disposable Claude/Codex sessions with an r8 runtime
and configured hooks. Check prompts and receipts, allow once, exact always
rules, deny, terminal/remote answer races, expiry, reconnect and revocation.
Check the unchanged controller/deadline around each approval action. Codex
may require its first local prompt before chat becomes available. Read-only
Genie discovery is useful evidence but does not establish this whole provider
mutation matrix. Do not edit/build an Atem checkout here; hand requirements
to the Atem owner through docs/memory.
