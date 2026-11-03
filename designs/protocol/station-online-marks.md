# Online Chisel marks

Status: sender handoff on PR #70's reviewed SDK, 2026-11-03. No deployment or
production enrollment. The separate `host-work-api` gate applies to marks as
well as launch/messages. It remains off in normal and existing `hosted-agent-api`
builds; existing approved dev hosted execution is unchanged. Offline delivery,
artifact retention, replay and automatic launch are outside this increment.

Companion Chisel publisher: https://github.com/Agora-Build/chisel/pull/1,
commit `ddd2f0a96177ac601d0f2c6ab95109b5a1ada4d2`.

## Delivery

Chisel's Node middleware saves its annotated PNG and task JSON locally, reads a
service token from its server environment, and resolves the exact configured
session from Station's authenticated session list. It sends the actual PNG;
task IDs and local paths alone cannot transfer an image. The browser receives
neither the integration token nor service keys.

Station checks its existing OIDC token, current integration policy, signed
membership, approved service key and proved host route. One encrypted R9
channel uploads ordered `attachment_put` chunks then publishes one typed
`message_publish.mark` as its own authenticated service principal. It cannot
assert that it is the native user. Atem rechecks sender authority and its local
route before submission. Marks and ordinary messages share the FIFO queue per
session. Claude and Codex receive a verified local PNG path.

The HTTP response owns the host channel while work waits or runs. Dispatch
requires the sender's live authorized channel. Disconnect, policy denial,
token expiry, membership-head change or the ten-minute deadline closes it;
no Station job continues after response closure. Host receipts remain durable.
At most four mark streams run per replica; they use a separate bounded permit
pool so waiting marks leave the ordinary API available for approvals and control.
Work accepted before disconnect may already have started; disconnect is not
cancellation. No mutation is automatically retried.

## API

`POST /api/agent/v1/integrations/:id/hosts/:host/sessions/:session/marks`

Bearer scope: `agent.prompt`. Chisel also uses `agent.view` for target lookup.
The signed service grant needs `view`, `message`, `notify` and `prompt` within
the selected host/session/project scope. Atem must advertise `host.attachments`,
`host.messages` and `host.work`, enable hosting, and approve this service in the
profile and route. The endpoint never launches an agent, takes over control or
resolves approvals.

The strict JSON body (maximum 12 MiB) has these fields:

| Field | Meaning |
| --- | --- |
| `target` | Exact account, host, trust generation, session and process generation from the session list |
| `route_id`, `route_revision` | Explicit locally approved Atem route |
| `message_id`, `workflow_id`, `recipient_id` | UUID v4 immutable publication/work identities; recipient ID is task ID |
| `created_at`, `expires_at` | Milliseconds; frozen before sending, within the message lifetime bounds |
| `mark` | Typed `mark_id`, URL, title, screenshot descriptor and annotation array from the Atem contract |
| `png_base64` | Standard padded base64 of the entire PNG, never a URL or path |

The screenshot descriptor contains UUID v4 `attachment_id`, lowercase SHA-256
`digest`, decoded byte `size` and `media_type: "image/png"`. An annotation has
`tool`, `text`, `x`, `y`; Chisel rounds positions to integer screenshot pixels.
Station verifies metadata, size, digest, signature and IHDR bounds before any
upload; Atem verifies them again. Limits: 8 MiB, dimensions 16384 each and
40 million pixels. The shared SDK's mark/message bounds also apply. Uploads use
at most 96 KiB decoded per chunk and wait for a bound durable acknowledgment.
Station holds the image in memory for this request and creates no artifact store.

Before streaming starts, normal authenticated JSON errors apply, including
`stale_target`, `host_upgrade_required`, and `mark_grant_required`. Release-gate
and authentication errors preserve their existing status and headers. The
response uses `application/x-ndjson`, `Cache-Control: no-store` and
`X-Accel-Buffering: no`:

```jsonl
{"event":"accepted","message_id":"...","work":{"task_id":"...","receipt_id":"...","state":"queued","detail":"...","result":null}}
{"event":"work","work":{"task_id":"...","receipt_id":"...","state":"submitted","detail":"...","result":null}}
{"event":"work","work":{"task_id":"...","receipt_id":"...","state":"awaiting_result","detail":"...","result":null}}
{"event":"end","state":"awaiting_result","task_id":"..."}
```

`accepted` means durable task acceptance, not successful implementation. `work`
repeats at least every five seconds while monitoring, keeping ordinary HTTP
proxies active. The stream ends at `awaiting_result` or a terminal task state.
Only an explicit correlated `work_complete` result confirms completion.

Failures after streaming starts produce:

```json
{"event":"error","code":"host_connection_lost","delivery":"uncertain","message_id":"...","task_id":"..."}
```

`delivery` is `not_published`, `uncertain` or `accepted`. A lost publish reply is
uncertain. Chisel retains the original IDs and files and never automatically
reposts or creates replacement IDs. Sender acceptance has a 30-second timeout;
monitoring lasts at most ten minutes. Node must stay running. Local task JSON
distinguishes `not_sent`, `delivery_unknown` and `monitoring_lost`; the last
means acceptance is known but later progress is lost. There is no restart replay.

## Provisioning and compatibility

Native provisioning accepts optional `markTasks: true`, default false. It
requires Portal `agent.view` and `agent.prompt` consent and adds `message` and
`notify` to the new grant reviewed and signed by the owner. Existing grants
stay unchanged. `StationIntegrationHTTP.prepare` and `RemoteServiceReview.check`
take matching opt-in parameters. Older grants get `mark_grant_required`.

Rust and the native Apple package retain PR #70's immutable shared-client pin,
`2b0c384e7213e5d4637cdba1f0a78ccbc53a2083`. This patch contains no unpublished
SDK snapshot, dependency change or replacement native consent implementation.
PR #70 already exposes the explicit, default-off mark choice and checks the
exact signed operations. Before real enrollment, upgrade all participating
strict account-membership verifiers. Auth #14 / Portal #25 permission agreement,
native consent for the proposed generic scopes and live launch/attach/mark
acceptance remain activation gates. This patch does not activate the API or
enroll a live service. See `host-work-integration.md` for those owners.

## Verification

The isolated Postgres HTTP/R9 test covers exact PNG bytes over three chunks,
service identity, current targets, grant opt-in, progress, lost replies, policy
denial and disconnect cleanup. `CHISEL_MARK_TEST_SCRIPT` invokes Chisel's built
Node middleware against the real Station HTTP listener and encrypted host
fixture. The host is test code using shared R9 crypto, not a live provider or
the Atem runtime. Atem's `host_work_binary` separately tests the real runtime,
PNG materialization, queue order and fake coding CLIs.

```sh
# RECOVERY_TEST_DATABASE_URL must select an isolated local Postgres server.
CHISEL_MARK_TEST_SCRIPT=/absolute/chisel/tests/station-live.mjs \
  cargo test --locked --features host-work-api hosted_agents::tests::mark_tests -- --include-ignored --test-threads=1
```

Chisel: `npm test`. All tests use fixture credentials.

At this handoff, all 562 relay unit tests in the host-work build and all 13
focused HTTP/R9 tests pass, including nine isolated Postgres cases. The marks
case exercises all eight modes, including the real built Chisel middleware.
Ten focused tests also pass in an existing `hosted-agent-api` build with marks,
launch and messages still gated off. These results do not replace live
native/provider acceptance.
