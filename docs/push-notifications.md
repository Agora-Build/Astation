# Agent approval notifications

Push notifications deliver a request to a device with control permission even
when that device has no lease. A tap reconnects and reads the approval from an
authenticated Atem. An explicit answer uses the exact pending request and
current control permission without changing the lease. The relay and the
notification payload cannot approve anything.

Current application behavior is r9: approval answers and rule revocation need
control permission and the exact authoritative request/rule, without acquiring
or changing a terminal lease. The relay/notification cannot authorize an answer.
See the [r9 client](../designs/protocol/r9-client.md) and
[local approval API](local-control-api.md) for implemented behavior and tests.

Remote multi-device admission and sealed escalation are designed on
[Atem PR #80](https://github.com/Agora-Build/Atem/pull/80), coordinated through
[#81](https://github.com/Agora-Build/Atem/issues/81). The approved policy is:
desktop OS push immediately if no desktop is connected; mobile at 60 seconds
if unanswered and not actively seen; optional desktop reminder/mobile immediate
preference; suppression near expiry without disabling a valid answer early.
See the [aligned push integration plan](../designs/protocol/approval-push-proof.md).
Signed ingress, native verification, sealed provider payloads and foreground
attendance are implemented using the pinned shared verifier. Durable provider
stage jobs and membership-bound token registration still gate actual dispatch.
Neither a headless API test nor a provider fake proves actual APNs delivery.

## Current implementation boundary

- **In-app alerts** show a nonmodal banner and an approval inbox while Astation
  is running. They require neither APNs nor OS notification permission. The
  menu is directly under Astation and shows the pending request count.
  Turning alerts off retains the inbox and does not change offline push.
- The inbox reads r9 `approval_request` / `approval_closed` from authenticated,
  encrypted Atem channels. Requests arrive independently of
  control leases. Catch-up replaces existing cards without repeating alerts;
  disconnect, permission loss and process changes disable stale answers.
- Allow once, Deny (with an optional message) and Claude/Codex offered Always
  allow rules use durable lease-free r9 approval submissions. Show and confirm
  the exact offered rule and scope. Reconnect queries receipts and never
  repeats a decision. An unknown outcome requires checking the agent instead
  of answering again.
- **Offline APNs push** is a separate opt-in. Native macOS can request OS
  notification permission and register its APNs
  token, re-register on an authenticated relay reconnect and unregister on opt-out.
  A build without the APNs entitlement disables only this option, with an
  explanation; the in-app option and inbox remain usable.
- The relay persists legacy registrations in Postgres (`0008_device_push_tokens.sql`).
  Only the current native socket that proved the Astation key can change its
  address. Body fields cannot select an account or another device. These
  registrations prove a separate relay key and are **not** r9 push destinations.
  A device-ID match cannot substitute for membership-key proof.
- APNs and FCM provider adapters validate configuration, authenticate provider
  requests, set collapse/tag identity, bound complete payloads
  and distinguish invalid addresses from temporary or configuration failures.
- A resolution removes matching delivered/pending notifications on the client.
  Bounded persisted tombstones suppress late duplicate transport alerts.
- Signed host `push_hint` / `push_seen` ingress verifies the current membership
  chain, host key/trust generation and captured carrier context. Postgres
  commits sealed records, dispositions and resolution tombstones before ACK.
  Retries and replica failover preserve original receipt and signed times.
  Plaintext push messages are refused.
- Visible cards in a focused foreground window with physical input in the
  last 60 seconds report `approval_seen` with a read binding, without a lease.
  Background deliveries and unattended windows do not report attendance.
- Native OS delivery verifies the signed envelope, current recipient/key and
  membership before protected checkpointing or presentation. Taps verify again.
  The current Mac adapter uses generic OS text; it does not decrypt a summary.
  A push tap reconnects, requests fresh session lists and opens
  the same inbox; push metadata never supplies an actionable request or rule.
  If no authoritative matching request is available, the UI says its status is
  unconfirmed. An unavailable or partial catch-up is never called "answered".

The shared r9 contract is pinned at
`c685abab92535b167f5f2658c814f0f72541d9a1`; there is no older protocol fallback.
See the [r9 lifecycle](../designs/protocol/r9-client.md) and
[sealed ingress implementation](../designs/protocol/sealed-push-relay.md).
Provider dispatch remains disabled (`push_ready: false`). Live APNs delivery
and phone workflows are not verified. Offline push still requires the durable
delivery worker, membership-bound registration, provider credentials and
provisioning. Independent encrypted relay channels do not require an online Mac.

## Apple setup

1. Use an Apple Developer team that can provision Push Notifications for the
   intended explicit app identifier. Merely logging in to Xcode or signing an
   ad-hoc app does not authorize APNs. The production Mac bundle identifier is
   `build.agora.astation`.
2. Enable Push Notifications for that identifier. Create an APNs token signing
   key, record its key id and team id, and download the `.p8` once. Store the key
   in the credential vault; never commit it or put it in memory.
3. Regenerate a matching provisioning profile. A macOS profile must authorize
   `com.apple.developer.aps-environment`. Local packaging copies that entitlement
   only if the profile grants it. Public release signing accepts `production`
   only and never invents an entitlement absent from the profile.
4. Mount the key read-only in each relay container and set the four APNs
   variables in the table below. Set the topic to the signed app's actual bundle
   identifier. Use a separate test relay for a different local bundle id/topic.
5. In Astation, choose Astation > Approval Notifications and enable
   **Offline APNs push**. **In-app alerts** work with a free Xcode Personal Team
   profile; APNs requires an eligible paid Apple Developer Program team.
   If macOS refuses permission, allow Astation in System Settings > Notifications
   and enable offline push again. The window explains a missing APNs entitlement
   without preventing access to the inbox.

The adapter routes development tokens to Apple's sandbox and production tokens
to production. One configured APNs topic is supported per relay deployment;
additional app topics need an allowlisted registration design before shipping.

## Firebase setup

1. Create/select the Firebase project for the Android app and register its
   package. Enable the Firebase Cloud Messaging HTTP v1 API.
2. Provision a service account authorized to send FCM messages in that project.
   Store its JSON private key in the credential vault, then mount it read-only
   in both relay replicas. The adapter uses its project id, client email and
   RSA private key for a scoped OAuth token; it does not accept arbitrary token
   exchange URLs from the file.
3. Set `FCM_SERVICE_ACCOUNT_FILE`. Do not use a client Firebase config file as
   the relay credential. An Android client must create the `agent_approvals`
   notification channel, request notification permission, register/rotate its
   token as an authenticated member device and cancel resolutions by approval id.
4. Phones must enroll as control members and prove their membership key when
   registering. That registration flow is still pending. An account login or
   the existing storage-device list is insufficient.

## Relay configuration and deployment

| Variable | Purpose |
| --- | --- |
| `APNS_KEY_FILE` | Read-only mounted PKCS#8 `.p8` key file. |
| `APNS_KEY_ID` | APNs key identifier. |
| `APNS_TEAM_ID` | Apple Developer team identifier. |
| `APNS_TOPIC` | Bundle identifier authorized for the token. |
| `FCM_SERVICE_ACCOUNT_FILE` | Read-only mounted Firebase service-account JSON. |
| `DATABASE_URL` | Postgres shared by relay-a and relay-b; stores token registrations. |

No provider variables means provider delivery is disabled. Partial or invalid
configuration fails startup with a fixed error that contains no key/token
values. Credentials load from files and never enter the database. Do not put
private keys in Docker build arguments or image layers. Give the container user
read access to the mounted files and restrict host permissions.

For Coolify, mount the same secret files and configure the same topic/project
on relay-a and relay-b. Apply the additive migration before enabling delivery.
Roll one replica at a time with `/health` checks, following the existing relay
deployment procedure. Configuring credentials alone does not turn on the gated
provider dispatcher. A merge to main deploys production and requires user approval.

## Delivery and privacy limits

APNs collapse ids coalesce pending notifications, but do not guarantee removal
of a delivered alert. Resolutions use background APNs/data-only FCM messages;
the client cancels matching notifications. The FCM alert's Android tag is
`approval_id`; signed resolution data carries the same full approval identity
for cancellation. Background
delivery is best effort, so foreground/reconnect catch-up must reconcile every
pending card before it can be answered. A failed catch-up is not "already
answered".

Alerts use `mutable-content:1` for a future iOS notification service extension.
The provider payload's `r9_hint` carries one original signed recipient envelope;
tool and summary remain HPKE ciphertext. Provider-visible alert text is generic.
There is no iOS extension yet. If the protected encryption key is unavailable,
show generic text and fetch current state after unlock, without an interactive
biometric prompt from notification code. Do not include raw tool inputs or
transcript content in push hints.

Before enabling live delivery, the membership integration must revalidate
control membership/revocation at send time and bind registrations to the enrolled
member key/trust generation. Key replacement, removal and revocation must fence
old addresses until current authority is proved again. Persist an idempotent
approval and resolution outbox across both replicas, and invalidate failed token
generations conditionally. Provider adapters alone do not implement that dispatch
lifecycle.
