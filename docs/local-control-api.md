# Local session and approval API

The optional local API uses the running native Astation's verified Atem session
clients, approval inbox and durable request journal. It lets a script exercise
the same flow as a future mobile UI. It does not enroll devices or bypass
verification, permissions, attachment/process checks or control leases.

## Enable locally

Create a private random key file once. Keep it outside git and shared file
hosting. The file must be a same-user regular file, mode 0600, with one hard
link; symlinks are rejected. The example never prints the key:

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

Quit the old Astation, then open the provisioned bundle with the opt-in:

```sh
open --env "ASTATION_LOCAL_API_TOKEN_FILE=$HOME/Library/Application Support/Astation/local-api-token" \
  '/Users/brent/Dev/Agora.Build/Astation/.build/Astation Local.app'
```

The token grants local session control to a process that can read it. Never
share it with a web page, put it in argv, or publish it in memory/docs. The app
loads it at startup; quit/relaunch to rotate it or disable the API. Launching
normally without the environment variable leaves every API route disabled.
The key file must contain 64 lowercase hexadecimal characters and an optional
final newline. Invalid configuration leaves the API disabled.

Requests use the existing port 8080, but API admission requires the actual peer
to be loopback, one matching Authorization: Bearer header, and no Origin.
Forwarded addresses are ignored. No CORS, caching or redirects are supported.
POST requires Content-Type: application/json, <=64 KiB, no duplicate JSON keys,
and protocol-safe integers. Responses close the HTTP connection. The key and
request bodies are never added to Astation's network debug logs.

## Commands and routes

The client reads the key from a protected file; it never passes it to curl:

```sh
export ASTATION_LOCAL_API_TOKEN_FILE="$HOME/Library/Application Support/Astation/local-api-token"
python3 scripts/astation-api.py status
python3 scripts/astation-api.py sessions
python3 scripts/astation-api.py approvals
python3 scripts/astation-api.py post approvals/answer --file /private/path/answer.json
```

| Route | Input or output |
| --- | --- |
| GET /api/v1/status | API/session revision and explicit account-trust/push ingress gates. |
| GET /api/v1/sessions | client_id, current registry descriptors, full target, phase/status and whether control is held. A target can be absent while connecting. |
| GET /api/v1/approvals | Exact request snapshot, full target, client_id, provider/host, can_answer, status and authoritative resolution if known. |
| POST /api/v1/sessions/acquire | client_id, full target, optional takeover (default false). 202 is a request, not a granted lease. Poll sessions for controls:true. |
| POST /api/v1/sessions/release | client_id and full target. Releases local control. |
| POST /api/v1/sessions/submit | client_id, full target, caller-generated request_id UUID, kind prompt/interrupt/stop, text for prompt. Requires current control. Codex without chat-v1 uses its native terminal for prompts. |
| POST /api/v1/approvals/answer | client_id, full target, new request_id UUID, approval (exact request from GET), decision allow_once/allow_always/deny, optional rule (exact offered object), optional denial message. |
| POST /api/v1/receipts/query | Full target and request_id. Reads the local durable record and latest authenticated host receipt; an absent receipt is unconfirmed. The session client refreshes unresolved receipts from Atem. |

A full target has account_id, atem_device_id, host_trust_gen, session_id and
process_gen. Copy it from the current list; a label, hostname or session id alone
cannot identify an authority boundary.

For an answer, copy the entire approval request object unchanged. Always allow
also echoes the exact rule_id, label and scope offered by Claude; Codex cannot
use it. A denial may include message (up to 512 UTF-8 bytes). Do not convert a
notification's fields into an answer request; only authenticated catch-up
supplies the authoritative card. Closed/unavailable cards return 409.

Submission 202 means journaled locally, not executed. Keep the request_id and
poll receipts for accepted/executing/completed/rejected/outcome_unknown.
An identical POST retry returns the existing request without another submit;
changed target/kind/payload with that id returns 409. Never make a new UUID to
retry an uncertain answer. Journal retention is bounded (4096 records; final
records may be evicted), so it is a recovery aid rather than unlimited history.
Reconnection queries original host receipts and never restores control or
replays a prompt/decision. Unknown outcomes require checking the agent.

## Verification matrix

Automated Swift tests use real session validation, durable journaling and the
HTTP listener, with deterministic host messages. They cover API admission,
body limits, duplicate keys, control requirements, exact snapshots/rules,
duplicate/reused request ids, closure/expiry, stale contexts and receipt scope.

For **live** tests, have Atem launch isolated Claude and Codex test sessions
using the r7.1 runtime at Atem PR #72 / 6edda24 and approval hooks. The installed Atem on this Mac
is 0.6.9 and is not the PR #72 host; do not build/edit an Atem checkout here.
Stage prompts in those sessions, then use this API to review and answer:

1. Claude Allow once, exact offered Always allow, and Deny with a message;
   check both the durable receipt and the agent's observed action.
2. Codex Allow once and Deny; verify Always allow is refused.
3. Cross a local terminal answer with a remote answer; honor the host's
   completed/rejected/outcome_unknown result without repeating it.
4. Let a request expire; ensure the card cannot be answered, including via API.
5. Reconnect with a pending and then a closed request; duplicate catch-up must
   create neither duplicate cards nor repeated alerts/submissions.
6. Disconnect immediately after a 202 response and query the same receipt.

None of this needs a mobile client. Membership/freshness and host push APIs
still need the [joint trust review](../designs/protocol/account-trust-review.md)
and [push-proof agreement](../designs/protocol/approval-push-proof.md). Provider
test transports verify requests without a phone; only a real push-enabled
profile, provider credentials and token can establish actual APNs delivery.
The [joint session matrix](../designs/protocol/session-validation.md) records
automated coverage and confirmed live results, including the host-side r7.1
replacement-hello fixture boundary.
