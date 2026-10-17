# Push-based agent approvals

## Connected alerts and offline push

The native client now targets the r7 approval contract published in Atem PR #72
at `5ce333e505e77429ffbfd443bdb0794b45136a03`. In-app alerts and the approval
inbox work independently of APNs provisioning or OS notification permission.
Offline APNs is a separate opt-in; enabling or disabling it never changes the
in-app preference. Existing push opt-in is preserved when migrating preferences.

Only the safety-code-verified session client supplies inbox requests. Bind each
card to its authenticated account, host trust generation, session and process.
Drop actionable state when that context changes, the session ends or authority
expires. Repeated catch-up events replace cards without repeating alerts; a
resolution fences delayed opens. Notification payloads only locate catch-up,
never supply a rule or authorize a decision. An unavailable catch-up must remain
distinguishable from an answered request.

Explicit answers use r7 `kind:approval` with `acquire:true` atomically, after
durably recording the request identity. Never send a separate acquire or replay
the decision on reconnect. Show only authoritative offered Claude rules;
Codex has no Always allow. Query durable receipts after delivery uncertainty.

APNs registration still requires a profile authorizing the push entitlement.
Live offline dispatch stays gated on authenticated host-to-relay proofs and
provider configuration; an online in-app alert must never imply offline push
delivery has been provisioned or tested.

Status: native r7 integration implemented against Atem PR #72 at
`5ce333e505e77429ffbfd443bdb0794b45136a03`. Existing session and terminal
semantics are retained; approval messages follow r7 with no legacy fallback.
Relay host ingress and account-wide fanout remain gated.

Recovery closes and reopens the transport before a new hello, including an
initial pairing-time refusal. Retry uses fresh relay/session authentication;
there is no same-socket or timer hello retry. Sleep closes transports and fences
authority; a post-welcome unauthorized reply reconnects once. A local socket
generation supplements the surviving host connection id. Never restore leases
or replay submissions. See the [recovery plan](2026-10-16-session-reconnect.md).

## Lifecycle and security invariants

1. Push delivery is a hint, independent of any control lease. Receiving or
   tapping a notification never acquires control or submits a decision.
2. Registration belongs to the native device that proved its relay key, never
   an account/device identifier supplied in a registration body. Account login,
   data-account grouping and relay room presence do not confer control roles.
3. A host's authenticated identity and account must be captured before async
   dispatch. The current relay authenticates Astation keys, but an Atem room
   join does not authenticate an Atem device. Do not enable host push ingress
   until its proof/membership contract supplies that context. Never derive it
   from push_approval.atem_device_id, a hostname or a room code.
4. The future membership integration supplies recipients with verified control
   membership. Before membership exists, only the verified paired Astation is
   eligible. No account-wide fanout based on SSO or storage grouping.
5. On a tap, wake/reconnect, authenticate, fetch authoritative pending approvals
   from Atem, and correlate the exact host/session/process/approval. Push text,
   cached data and relay state cannot authorize an answer. A stale tap displays
   "Already answered" without taking a lease. An offline/failed catch-up stays
   unresolved; it must not be mistaken for an authoritative absence.
6. Allow once / Always allow / Deny send a durable approval submission with
   acquire:true. Atem atomically takes the lease and decides the exact prompt.
   Never approximate this with separate acquire and submit messages. Claude's
   Always allow requires the authoritative rule and explicit user confirmation;
   Codex never offers it. The implementation follows the published r7 wire schema.
7. Payloads contain only tool and a short redacted summary; never raw inputs,
   transcripts, credentials or decisions. Log no device tokens, provider keys,
   approval summaries or provider response bodies. Set mutable-content:1 for
   future on-device decryption; this alone does not encrypt today's payload.
8. Use approval_id as APNs collapse-id / FCM tag. A resolved notification causes
   the client to remove the delivered/pending notification and record a bounded
   tombstone. Collapse IDs coalesce pending APNs deliveries; they do not reliably
   remove an already delivered alert. Background pushes may be delayed. Catch-up
   must reconcile state after foreground/reconnect, including lost resolutions.
9. Tokens rotate, can be revoked and expire at providers. Registration is
   idempotent, replaces the old token for this device/provider/environment, and
   is persisted outside relay process memory. Invalid-token responses remove
   only the exact registration generation that failed, not a newer token.
10. Provider credentials are server secrets loaded from mounted files. APNs
    requires the matching app topic, environment and push entitlement/profile;
    FCM requires a Firebase project/service account and Android client setup.
    Development/ad-hoc Mac builds cannot claim working background APNs without
    those prerequisites. Delivery stays disabled without configuration.

## Independent work

- Isolated worktree: Astation-push-approvals, feat/push-approvals.
- Add validated notification payloads and APNs/FCM transport adapters, with
  injectable HTTP transport and clocks for real request/response tests.
- Register/unregister this native device's push token through its verified
  relay control connection; persist registrations and handle token rotation.
- Native notification reconciliation and tap handling must use an authoritative
  approval-source interface, rather than inventing r7 message shapes.
- Document provider provisioning, environment variables, mobile membership
  gates and the upstream contract requirements in the hosted handoff.

## External dependencies

- Authenticated Atem-to-relay push context and signed membership wire contract.
- APNs key/team/topic/profile and Firebase service-account credential names.
- Actual iOS/Android clients and signed device enrollment before phone answers.

The user requested a provisioned local build and restart. The existing personal
team, bundle identifier and Keychain access group are retained. No merge or
production deployment is included.
