# Agent approval notifications

Push notifications deliver a request to a device with control permission even
when that device has no lease. A tap reconnects and reads the approval from an
authenticated Atem. Only an explicit answer may atomically acquire control and
answer the exact request. The relay and the notification payload cannot approve
anything.

The accepted product flow is Atem PR #70, `designs/account-trust.md`,
"Push-based approvals". That section supersedes the earlier requirement that a
lease must already exist to receive an approval. See the
[implementation handoff](../designs/protocol/push-approvals-handoff.md) for the
remaining wire-contract gates.

## Current implementation boundary

- Native macOS can opt in, request OS notification permission, register its APNs
  token, re-register on an authenticated relay reconnect and unregister on opt-out.
- The relay persists registrations in Postgres (`0008_device_push_tokens.sql`).
  Only the current native socket that proved the Astation key can change its
  address. Body fields cannot select an account or another device.
- APNs and FCM provider adapters validate configuration, authenticate provider
  requests, set collapse/tag identity, bound payloads, redact detected secrets
  and distinguish invalid addresses from temporary or configuration failures.
- A resolution removes matching delivered/pending notifications on the client.
  Bounded persisted tombstones suppress late duplicate transport alerts.
- Host push ingress, account-wide recipients and decision buttons are disabled.
  The relay currently authenticates Astation keys, not an Atem device's key on
  its room socket. r6.2 rejects approval submissions and has no approval catch-up.
  A tap in this build explains that review is unavailable and opens Connections;
  it never claims the approval was answered or submits terminal keystrokes.

This is transport preparation, not an end-to-end approval release. Neither
live provider delivery nor phone approval has been verified.

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
5. In Astation, choose Tools > Approval Notifications and enable notifications.
   If macOS refuses permission, allow Astation in System Settings > Notifications
   and enable it again. The menu explains a missing provisioning entitlement.

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
