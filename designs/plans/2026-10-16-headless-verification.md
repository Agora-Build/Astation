# Headless approval verification and trust review

The user requested API access so native/mobile UI availability does not block
protocol and approval tests. Reuse the running Astation's verified session
clients, inbox and durable journal. Do not create a test-only approval authority.

## Local automation API

Enable only with `ASTATION_LOCAL_API_TOKEN_FILE`, pointing at a regular,
same-user, mode-0600 file containing a random 32-byte lowercase hexadecimal
token. Reject symlinks and unsafe permissions. No token is logged or returned.
The existing listener accepts API calls only from loopback, without an Origin,
and with that bearer token. All responses close the HTTP connection, disable
caching and omit CORS. Bound request bodies and reject duplicate JSON keys.
Production launch without the environment variable exposes no API.

The API lists authenticated sessions, approval cards and durable receipts;
requests control, submits prompts/interrupts, releases control, and answers an
exact approval snapshot. The same permission, process, attachment, lease and
revocation checks as the UI apply. Always-allow requires echoing Claude's exact
offered rule. No API enrolls or verifies a device, changes account trust, reads
credentials, or manufactures an agent approval.

Every submission requires a caller-generated UUID request id. Persist it before
send. An identical retry returns the original request; changed target, kind or
payload with the same id is refused. Reconnect only queries receipts. A 202
response means locally journaled, not executed or approved by the agent.

Use a headless client with an isolated test Atem session for the live matrix:
Claude allow once/exact always rule/deny, Codex allow/deny, local answer races,
expiry, reconnect catch-up, duplicate submissions and stale cards. Do not send
test prompts to a user's existing working agent session.

## Joint trust gate

Review Atem #70 at `1e5f4d0`, preserving its user decisions. Publish concrete
membership and authenticated push-proof requirements for joint review before
enabling account-wide trust or a new host push ingress. The relay stores and
routes signed data; account login, room identity and push tokens grant no
control. APIs and provider fakes can validate logic without a mobile app;
actual APNs delivery still requires an eligible profile, credentials and a
registered real token. Do not claim that provider fakes verify Apple delivery.
