# Agent approval notifications

Push notifications deliver a request to a device with control permission even
when that device has no lease. A tap reconnects and reads the approval from an
authenticated Atem. An explicit answer uses the exact pending request and
current control permission without changing the lease. The relay and the
notification payload cannot approve anything.

Current application behavior is r8: approval answers and rule revocation need
control permission and the exact authoritative request/rule, without acquiring
or changing a terminal lease. The relay/notification cannot authorize an answer.
See the [r8 client](../designs/protocol/r9-client.md) and
[local approval API](local-control-api.md) for implemented behavior and tests.

Remote multi-device admission and sealed escalation are designed on
[Atem PR #80](https://github.com/Agora-Build/Atem/pull/80), coordinated through
[#81](https://github.com/Agora-Build/Atem/issues/81). The approved policy is:
desktop OS push immediately if no desktop is connected; mobile at 60 seconds
if unanswered and not actively seen; optional desktop reminder/mobile immediate
preference; suppression near expiry without disabling a valid answer early.
See the [aligned push integration plan](../designs/protocol/approval-push-proof.md).
Wire schemas/fixtures, authenticated host proof, sealed hints, active-user seen
and a durable relay scheduler are not implemented by provider setup alone.
Neither a headless API test nor a provider fake proves actual APNs delivery.

## Current implementation boundary

- **In-app alerts** show a nonmodal banner and an approval inbox while Astation
  is running. They require neither APNs nor OS notification permission. The
  menu is directly under Astation and shows the pending request count.
  Turning alerts off retains the inbox and does not change offline push.
- The inbox reads r8 `approval_request` / `approval_closed` from authenticated,
  safety-code-verified Atem session clients. Requests arrive independently of
  control leases. Catch-up replaces existing cards without repeating alerts;
  disconnect, permission loss and process changes disable stale answers.
- Allow once, Deny (with an optional message) and Claude/Codex offered Always
  allow rules use durable lease-free r8 approval submissions. Show and confirm
  the exact offered rule and scope. Reconnect queries receipts and never
  repeats a decision. An unknown outcome requires checking the agent instead
  of answering again.
- **Offline APNs push** is a separate opt-in. Native macOS can request OS
  notification permission and register its APNs
  token, re-register on an authenticated relay reconnect and unregister on opt-out.
  A build without the APNs entitlement disables only this option, with an
  explanation; the in-app option and inbox remain usable.
- The relay persists registrations in Postgres (`0008_device_push_tokens.sql`).
  Only the current native socket that proved the Astation key can change its
  address. Body fields cannot select an account or another device.
- APNs and FCM provider adapters validate configuration, authenticate provider
  requests, set collapse/tag identity, bound payloads, redact detected secrets
  and distinguish invalid addresses from temporary or configuration failures.
- A resolution removes matching delivered/pending notifications on the client.
  Bounded persisted tombstones suppress late duplicate transport alerts.
- Host push ingress and account-wide recipients remain disabled.
  The relay currently authenticates Astation keys, not an Atem device's key on
  its room socket. A push tap reconnects, requests fresh session lists and opens
  the same inbox; push metadata never supplies an actionable request or rule.
  If no authoritative matching request is available, the UI says its status is
  unconfirmed. An unavailable or partial catch-up is never called "answered".

In-app review targets the merged r8 contract in Atem #78 at
`4f87bab1289848cb6a0da5707d2e7830eb5c057d`;
see the [r8 lifecycle](../designs/protocol/r9-client.md).
The session compatibility trust gate still limits access to the verified paired
native Astation. Live APNs delivery, phones and account-wide approval access
are not enabled or verified. Offline push requires the host authentication and
dispatch integration as well as provider credentials and provisioning.

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
5. In Astation, choose Astation Hub > Approval Notifications and enable
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
4. Phones are not eligible until signed membership and connection proofs land.
   An account login or the existing storage-device list is insufficient.

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
host ingress. A merge to main deploys production and requires user approval.

## Delivery and privacy limits

APNs collapse ids coalesce pending notifications, but do not guarantee removal
of a delivered alert. Resolutions use background APNs/data-only FCM messages;
the client cancels matching notifications. The FCM alert's Android tag is
`approval_id`; resolution data carries the same id for cancellation. Background
delivery is best effort, so foreground/reconnect catch-up must reconcile every
pending card before it can be answered. A failed catch-up is not "already
answered".

Alerts use `mutable-content:1` for a future iOS notification service extension.
There is no extension or push E2EE in this change. Today's redacted text remains
visible to the relay and push provider; mutable-content is not encryption.
The host must redact summaries before sending them. The relay additionally
replaces summaries with detected credential patterns, but this is not a complete
secret detector. Do not include raw tool inputs or transcript content.

Before enabling live delivery, the membership integration must revalidate
control membership/revocation at send time and bind registrations to the enrolled
member key/trust generation. Key replacement, removal and revocation must fence
old addresses until current authority is proved again. Persist an idempotent
approval and resolution outbox across both replicas, and invalidate failed token
generations conditionally. Provider adapters alone do not implement that dispatch
lifecycle.
