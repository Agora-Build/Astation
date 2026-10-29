# Station hosted agent API

These typed handlers are wired on custom Stations, using the pinned shared
atem-client R9 service channel. **Production admission is hard disabled** until
the live Auth/native/host/relay-only/Mac-off flow is verified. Requests currently
return `hosted_execution_not_verified` (503) on a custom Station, or
`custom_station_required` (403) on the public relay. No environment variable
enables execution. This document describes the implemented adapter for review
and controlled tests, not a deployed service.

## Provisioning and approval

1. Register the custom HTTPS Station in Portal with its exact public origin
   and separate report-client public JWK. Configure the protected operator
   files described in [DEPLOY](../../DEPLOY.md#custom-station-integrations).
2. Sign in to Agora.Build in Astation. Select that Station in General and
   open Settings > Integrations > Load Requests. The native app requests
   `integrations:read integrations:approve` for Portal and `astation.remote`
   for the exact custom Station, in separate Auth profiles. Both verified
   subjects must equal the signed-in owner. Two browser authorization prompts
   are expected when these grants have not been saved yet. The native app
   waits for account registration on the selected Station before recovery
   storage requests. Selecting another Station reconnects its relay socket.
   If account security has not been set up, the request selector still loads;
   **Set Up Account Security** opens Settings > Security for explicit owner
   confirmation and Recovery Kit saving. Return and reload requests afterward.
3. Select the owned request, allowed hosts and optional session/project
   restrictions. At least one verified host must be explicitly selected before
   Review Access is enabled. An empty host list means a host must first be
   paired and verified into this account's signed membership log; account
   sign-in and Recovery Kit setup alone do not enroll an Atem host. Empty
   selections never request a service key or report an account-session change.
   Review Access requests the exact canonical draft from
   `POST /agora-build/v1/integrations/:id/provision`. Its camelCase body is
   `{genesisHash, managerId, expectedHead:{seq,hash}, signedAt, hosts,
   sessions?, projects?}`. The server verifies owner policy, anchored root,
   current manager/head, scope and time; it never signs membership.
4. The native shared verifier checks the draft against its independently
   anchored log. The screen shows account, root, key fingerprint, scope,
   operations, expiry and predecessor. Owner authentication confirms that
   exact body. Durable publication precedes Portal's approval POST.
5. Lost relay/Portal replies retain the saved body and signature. Reloading
   resumes the operation and reconciles Portal state before another POST.
   Account, Station and issuer changes invalidate the UI operation.

`POST /agora-build/v1/changes {cursor}` is only an unsigned coalesced poll
hint. `GET /agora-build/v1/details` requires `station.read` and returns generic
status plus the **public** report JWK. Browser preflight for this details path
permits the exact configured Portal origin; it grants no browser access to
native provisioning or independent encrypted channels.

## Routes

Prefix: `/api/agent/v1/integrations/:integration/hosts/:host`

| Method and suffix | Scope | Request / result |
| --- | --- | --- |
| GET `/sessions` | `agent.view` | Session descriptors, complete targets and pending approvals. |
| GET `/events` | `agent.view` | WebSocket: initial snapshot, then whole structured R9 session/chat events. |
| POST `/sessions/:session/history` | `agent.view` | `target`; optionally one of `before`, `next`, `turn_id`, `request_id`; ordered messages, history_end and coverage. |
| POST `/sessions/:session/prompts` | `agent.prompt` | `target`, UUID-v4 `request_id`, `text`; optionally confirmed `takeover:true` and `expected_controller`. |
| POST `/sessions/:session/interrupt` | `agent.interrupt` | `target`, `request_id`, `take_control:true`. |
| POST `/sessions/:session/stop` | `agent.interrupt` | Same explicit control requirement. |
| GET `/sessions/:session/approvals` | `agent.approve` | Target and current approval cards. |
| POST `/sessions/:session/approvals` | `agent.approve` | `target`, `request_id`, `approval:{approval_id,decision,rule_id?,message?}`. |
| POST `/sessions/:session/approval-seen` | `agent.approve` | `target`, `approval_id`; only when shown to an active foreground user. |
| POST `/sessions/:session/rules/revoke` | `agent.approve` | `target`, `request_id`, `rule_id`; lease-free. |
| POST `/sessions/:session/receipts` | `agent.view` | `target`, `request_ids` (1-64 UUID-v4 IDs). |

Use the target returned by sessions, not a target inferred from presence:

```json
{
  "target": {
    "account_id": "the-verified-data-account",
    "atem_device_id": "the-verified-host",
    "host_trust_gen": 3,
    "session_id": "ses-aaaaaaaaaaaa",
    "process_gen": "11111111-1111-4111-8111-111111111111"
  },
  "request_id": "22222222-2222-4222-8222-222222222222",
  "text": "Run the project tests"
}
```

The HTTP adapter opens a fresh authenticated attachment for each request and
matches the target against the new registry. It returns `{events:[...]}`,
including the host's errors or durable receipt; HTTP 200 alone does not mean
the coding agent completed the task. An accepted receipt precedes completion.
The adapter never reruns a mutation after losing its reply. A bounded wait
that loses the outcome returns `delivery_uncertain` with the caller's
request ID and target; reconnect and query receipts using the same ID.

Prompt Send acquires atomically when nobody holds control. A takeover carries
the exact `{controller_session,lease_epoch}` shown to the user. Interrupt and
stop require explicit control and acquire only an unheld lease; they cannot
silently take over another controller. Approval answers and rule revocations
do not acquire, renew or release another client's lease. Decision values are
`allow_once`, `allow_always` (with the exact offered rule ID), and `deny`
(optional message). Host-side first-answer, rule and request-digest checks
remain authoritative.

HTTP attachments close after the response; they do not retain or renew an
interactive control lease. Use the native Remote Terminal for that workflow.
WebSocket events are read-only. After its snapshot, send at most one
`{"target":{...}}` subscription to open that session's chat. Other text input
closes the stream; use the typed HTTP endpoints to mutate. Rich message parts,
Markdown, links, history coverage and truncation metadata remain structured.
Refresh the Auth token and reconnect when it expires; it is never sent in a URL.

## Admission and bounds

- Bearer access token: exact issuer, Station resource, owner, integration
  client, operation and current `r9_svc`; at most five minutes. Native tokens,
  Portal tokens and assistant `sid` tokens are refused on hosted agent routes.
- Fresh authenticated Portal policy (under 120 seconds), active integration,
  current expiry and scope, durable owner/root/service identity, and per-second
  quota shared through Postgres. No caller can choose another root or owner.
- Protected approved key, current unexpired service grant and proved host
  carrier. The shared library verifies sig_h/sig_c and revision 9 welcome.
  The relay cannot invent identity or R9 authority.
- Recheck policy and membership at dispatch and before response delivery;
  streams also recheck every second. Any membership-head change requires a new
  channel, including same-key service renewal/narrowing. The host also fences
  revocation and rejects stale process/attachment/lease generations.
- 64 KiB request bodies; 8 concurrent requests/streams per replica; 10-second
  response wait; at most 512 events / 4 MiB per aggregate response; bounded
  socket writes and existing relay queue/cluster limits. Unknown or misplaced
  command fields are refused.

Controlled tests exercise actual encrypted relay traffic without a Mac,
prompt/receipt/approval/revoke/history adapters, retained formatting,
same-key membership changes, policy denial, protected-key loss/corruption,
feed recovery/restart, CORS and the closed production gate. They do not replace
the joint real Auth/native/host execution and replica release matrix.

## Test without an app

No mobile app or Discord bot is needed to exercise these APIs. The headless
HTTP test runs a loopback API server, an ES256-signed test issuer with real
discovery/JWKS, isolated Postgres and a controlled R9 host. It uses the same
token verifier, protected service-key store, encrypted channel and operation
handlers as Station. Disposable test manager keys establish its service grant;
it does not use the owner's existing identity or replace native consent.

With `RECOVERY_TEST_DATABASE_URL` set to a dedicated local test database, run:

```sh
cargo test --locked --manifest-path relay-server/Cargo.toml \
  hosted_agents::tests::postgres_http_api_authentication_operations_reconnect_and_revocation_without_app \
  -- --ignored
```

The test covers session discovery, prompt acceptance, receipt lookup on a new
attachment, approval-answer and rule-revocation requests, formatted history,
authenticated WebSocket updates, and closing that stream after policy denial.
It also refuses missing/invalid tokens, wrong issuer/resource/owner/client/key,
native tokens, expired tokens, insufficient scopes, stale process targets,
invalid control flags, unknown fields and oversized bodies.

Only the test listener omits the production release gate. No environment or
API option enables execution on a running Station. The controlled host verifies
real channel cryptography but supplies test session replies; its accepted
receipt is not evidence that Claude or Codex performed an operation. Real Auth
issuance, protected native approval, the fixing Atem host, relay-only policy,
Mac-off routing and replica failover remain separate live release checks.

### Real-host service verification

The ignored test `hosted_agents::live::protected_service_against_real_host_keeps_public_execution_closed`
uses an already registered **disposable** Station and an owner-approved service,
without publishing readiness or exposing an execution bypass. The module is
compiled only for tests. It binds the dedicated Station's existing loopback
port and runs the complete public router, whose hosted endpoints still return
`503 hosted_execution_not_verified`. The existing listener must be stopped
first and restored afterward; keep the tunnel, database, protected key files,
host runtime and coding-agent process intact.

Supply the Station's normal protected configuration and these test inputs:

| Variable | Value |
| --- | --- |
| `LIVE_HOSTED_DISPOSABLE` | Explicit `yes`; never use a production Station or agent. |
| `LIVE_HOSTED_INTEGRATION` | Existing approved integration ID. |
| `LIVE_HOSTED_HOST` | Existing verified host ID. |
| `LIVE_HOSTED_SESSION` | Current disposable agent session ID. |
| `LIVE_HOSTED_PROCESS_GEN` | Its authoritative current process generation. |
| `LIVE_HOSTED_TOKEN_FILE` | Mode-0600 JSON containing a fresh real Auth `access_token`. |
| `LIVE_HOSTED_EVIDENCE_FILE` | File in an operator-private directory; new for a submission, existing for receipt recovery. |
| `LIVE_HOSTED_RECOVER` | Optional `receipts`: query the saved request only; never submit a prompt. |
| `LIVE_HOSTED_WITHOUT_NATIVE` | Optional `yes`: refuse native identity-room WebSocket connections and assert no Astation room owner before and after execution. |

Run only that ignored test, with `--exact --ignored --nocapture`. It verifies
the real token's issuer, Station audience, client, owner, operation and service
fingerprint against a fresh non-denied policy. The policy may be
`waiting_for_host`: readiness is what this test measures, while the existing
signed membership remains the host's authorization. No stored state is
changed to `ready`, no native consent is synthesized and no replacement key is
generated.

The native-unavailable case blocks `/ws?role=astation` in the test router only;
host connections and the independently authenticated service channel remain
available. It checks operation without the native identity-room connection,
not physical Mac shutdown or every independent native transport. A Station
running on the same Mac cannot prove physical Mac-off availability.

The runner opens the production service client using the protected approved
key and proved relay carrier, checks the current registry/process, and sends
one marker-only prompt with no tools or file changes. It saves and fsyncs the
request ID and complete target **before** sending, closes after the initial
receipt, and then reconnects to query that receipt and the ordered history.
A pass requires a completed receipt and the exact marker in an assistant
message. A saved evidence file refuses a new submission run. To recover an
interrupted or uncertain submission, set `LIVE_HOSTED_RECOVER=receipts` and
reuse that evidence file with a fresh token. Recovery verifies the complete
saved target against the current registry, then queries receipts and history
without submitting a prompt. Read-only connection attempts have a bounded
retry; no mutation is retried automatically.

Use ordinary words and a short number for the marker. High-entropy random
strings may correctly be removed by Atem's secret filter; a scrubbed marker
does not prove execution failed. Preserve the filter and inspect the durable
receipt and protected correlated history instead of replaying the request.

This is real Auth/key/channel/agent/disconnect evidence, separate from the
controlled-host HTTP adapter tests. It does not by itself verify public HTTP
admission, actual approvals, durable relay-only policy, revocation, the Mac-off
matrix or replica failover, and does not enable the hosted release gate.

On 2026-10-29, both the normal and native-identity-unavailable cases passed
against the disposable Codex host built from the accepted Atem source
`a2cc6711117b79a73298c27baee337e25f9d87af`, with shared client `ed0b45b`.
Each recovered its own completed request and matching assistant response after
disconnect, without resubmitting. The isolated Station was restored healthy
after each run and public hosted routes remained closed. Full evidence and
the remaining gates are tracked in [Atem #81](https://github.com/Agora-Build/Atem/issues/81).
