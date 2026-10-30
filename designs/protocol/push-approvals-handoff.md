# Approval notifications: Astation implementation and Atem handoff

Historical review/handoff: this records the earlier implementation and is not
the current remote-admission or approval contract. Use [r9-client.md](r9-client.md)
for shipped behavior and [remote-agent-api.md](remote-agent-api.md) for the
aligned r9 plan. Atem #81 owns handoffs; PR #80 owns the new shared contract.
Old freshness attestations, lease-taking approval answers and recovery/push
policies in this snapshot are superseded by those documents.

Updated 2026-10-16. Native approval integration uses Atem PR #72's r7.1 contract at
`6edda2490f4a4b7634edb446f64aa02748e29fa2`,
[`designs/protocol/atem-session-v1.md`, section 6a](https://github.com/Agora-Build/Atem/blob/6edda2490f4a4b7634edb446f64aa02748e29fa2/designs/protocol/atem-session-v1.md#6a-approvals-r7).
The user approved delivery independently of control lease ownership.

Worktree: Astation-push-approvals, branch `feat/push-approvals`, PR #50.
No Atem checkout was modified or built.

## Ready on Astation's side

- Approval Notifications is directly under Astation Hub, with a pending count,
  an inbox and separate In-app alerts / Offline APNs push switches. In-app
  banners and review work without APNs provisioning or OS permission. Disabling
  either channel does not change the other's preference or remove the inbox.
- The verified paired native session client consumes bounded r7
  `approval_request` / `approval_closed` messages. Requests arrive with no lease
  holder as well as during someone else's lease. Catch-up updates one card;
  closed ids suppress delayed opens. Loss of connection, permission, trust or
  the target process disables answers. Verification starts the subscription
  without requiring the user to first open Connections.
- Explicit Allow once / Deny / Claude Always allow send `kind:approval` with
  `acquire:true`, no lease epoch and the exact target/attachment. Recovery
  metadata is committed before send. Reconnect only queries receipts; no answer
  is replayed. Only the grant from this attachment's pending answer enables
  renewal. Local input and deadline expiry fence late grants. An unknown
  outcome cannot enable a second answer. Claude's exact offered rule and scope
  are shown and confirmed; Codex has no Always allow.
- APNs taps reconnect, request fresh session lists and open the same inbox.
  Push fields cannot create actionable cards, grant control or supply rules.
  The r7 contract has no end-of-approval-catch-up marker: an absent card remains
  unconfirmed rather than being called answered. An authoritative close can
  show that the request was answered elsewhere or expired.
- APNs registration, opt-out, reconnect and token rotation use the native
  device's key-verified relay socket. Postgres stores device addresses with
  digest uniqueness and generation-fenced invalidation. APNs/FCM adapters
  authenticate provider requests, set collapse/tag identity, bound payloads,
  redact detected credentials and distinguish invalid tokens from temporary
  failures. Resolution tombstones suppress delayed transport alerts.
- [Provider provisioning and deployment instructions](../../docs/push-notifications.md).
  A free Personal Team build supports the protected Keychain and in-app inbox;
  it does not grant the APNs entitlement. No provider credentials are configured.

## Remaining joint integration

The [local automation API](../../docs/local-control-api.md) now exercises the
real inbox/session/journal without a mobile app: exact-snapshot answers,
Claude rules, denial messages, control, idempotent UUID submissions and scoped
receipt reads. The HTTP listener is tested for opt-in/authentication/origin and
body limits. This is not a device-enrollment or test-impersonation endpoint.
Use isolated latest-runtime Claude/Codex sessions for the live matrix; the
installed local Atem 0.6.9 is older than the required PR #72 host.

The [#70 review](account-trust-review.md) identifies unresolved signature bytes,
enrollment/fork rules and the removed-manager fresh-nonce attack against the
24-hour revocation claim. The [push-proof draft](approval-push-proof.md)
specifies the proposed host certificate, connection proof, signed event,
durable dispatch and shared fixtures for Atem review. These are draft gates,
not enabled account-wide trust or push ingress. Astation no longer uses either
VisualizeRequest or VisualizeResult; no code cleanup remains on this side.

1. **Atem host authentication to the relay.** A current room socket proves no
   Atem device key. Its routing id and `push_approval.atem_device_id` cannot
   supply authority. Define a proof bound to the paired device key, account,
   host trust generation, connection generation and a fresh challenge, with
   revocation/reconnect fixtures. Capture validated identity before dispatch.
2. **Control membership.** Define signed membership bytes, genesis, sequence,
   signatures, roles, freshness and revocation. Until that lands, only the
   verified paired native Astation is eligible. Do not fan out to SSO devices
   or devices sharing memory/vault storage. Bind push addresses to the enrolled
   member key and generation; removal/replacement must fence old addresses.
3. **Durable relay dispatch.** Persist approval/resolution outbox state across
   both replicas. Revalidate recipient authority before send, expire requests,
   handle resolutions arriving first and invalidate failed token generations
   conditionally. Configuring provider credentials alone does not enable this
   gated ingress. Do not relay unauthenticated host messages into APNs.
4. **Live provider and host verification.** Supply an eligible push-enabled
   Apple profile and relay APNs credentials; Firebase credentials are needed
   for future Android clients. Run the paired native r7 flow jointly with
   Atem, then provider delivery/revocation/disconnect tests. No phone access,
   account-wide delivery, push E2EE or live APNs delivery is claimed today.

## Validation

Native coverage exercises no-lease approval arrival, atomic answers, exact
Claude rule selection, Codex restrictions, duplicate/catch-up suppression,
resolved-before-open ordering, process mismatch, immediate disconnect,
reconnect receipt recovery, persistence failure, local-input/expiry fencing,
unknown outcomes, text/numeric bounds and preference independence without APNs.
Session, terminal, menu and log-redaction regression tests are also run.

Local validation on 2026-10-16: 149 focused session/terminal/API/approval/menu tests pass;
the full Swift suite executes 898 tests with 11 environment-dependent skips
and zero failures. Relay push-related tests pass (16 tests, two database tests
ignored without their fixture).
The app is packaged with the existing personal-team provisioned identity,
passes strict signature and bundled-resource checks, and is running as
`Astation Local.app`. Its profile authorizes protected Keychain access but
does not grant APNs. The live verified Genie connection completes hello,
welcome, list and sessions; both Claude and Codex appear in Connections.
The local API submitted a harmless print-only prompt to the existing joint-test
Claude session and observed a completed receipt; identical UUID retry returned
the original request, altered bytes were refused, and control was released.
A subsequent delayed prompt completed after quitting/relaunching Astation
during execution; the original receipt recovered without restoring control.
No approval card was emitted, so no live approval was answered. Provider
delivery and a real pending-approval/answer/receipt round trip remain joint
validation work; Atem should stage a prompt that requires permission.
The [joint session matrix](session-validation.md) tracks r7.1 fixture, terminal,
lease, command and pairing checks separately from live results.

Existing relay provider tests use injected transports and verify actual
headers/body, ES256/RS256 signatures, OAuth refresh, expiry and provider
refusals. They do not contact Apple or Google. No new relay ingress or Atem
source modifications are part of this native integration.
