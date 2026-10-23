# Unified integrations and agent API access

Status: design draft for joint Portal, Auth, Station, Astation and Atem review,
2026-10-23. This document assigns proposed ownership and describes work to
build; it does not advertise deployed API endpoints or change the R9 contract.

## Product direction

Use one Agora.Build account page and one authorization model for built-in
connectors and custom applications:

```text
Account > Integrations
  Discord - My Server
  Custom App - My Dashboard
  Add Integration
    Discord
    Custom App / API
```

Discord is a preset of the same integration resource. A custom integration
can use the Station API with a Bearer token or, as an advanced connection method,
enroll its own key and use the R9 SDK. Do not create a separate developer API-key
page. Future public OAuth application registration describes a developer's
application; each user's authorized connection still appears here.

Both first-party and third-party integrations receive explicit permissions,
expiry and revocation controls. The official Discord connector provisions
credentials automatically; a custom API client can copy an API token once.
Native Astation apps continue using account login and their own enrolled
device keys. Browser clients retain the existing native-approved companion
model; this proposal does not turn browsers into standalone native members.

## Ownership and Station API

Agora.Build is the control plane: account/login/API authentication, integration
management and RTC/screen-sharing through Stoa. Station is the data plane on
the user's chosen server: private encrypted storage, R9 transport and runtime
agent-operation handlers behind one **Station API**. Native Astation supplies
manager confirmation; Atem verifies R9 authority and executes host operations.

Station validates credentials and applies authorized runtime configuration; it
does not become another identity provider, API-credential issuer or integration
management backend. Agora.Build manages the connection without proxying private
content through its backend.

Expose one Station API rather than requiring another publicly named service
or a separate gateway deployment. Implement agent integrations as a module in
the existing Rust Station server, using the shared `atem-client` crate. One
Station deployment and API origin can serve all modules. This is a design assignment, not a claim
that the new agent/integration routes already exist.

### What handles R9

There are two R9 responsibilities inside Station:

- **Transport:** existing WebSocket handlers carry encrypted R9 envelopes between
  native/direct clients and Atem. They do not hold endpoint keys or decrypt the
  channel. Atem authenticates the client and handles the host side of R9.
- **Agent integrations:** an optional module accepts ordinary HTTP/WebSocket API
  calls or Discord interactions and uses `atem-client` as an R9 endpoint. It
  holds a separate service identity for each authorized integration and reads
  that integration's permitted agent requests/results.

R9 service identities are protected durable state of the agent module, not
another public service users must deploy. The module must still authenticate
to Atem through R9, even when it shares a process with the transport. No internal call may skip
membership, scope, expiry, lease, receipt or generation checks.

### Private-data boundary

The user requires memory, vault data and user-stored credentials to stay on
chosen Station infrastructure, including self-hosted or friend-shared servers.
Agora.Build must not become another private-content store or a mandatory
plaintext agent proxy.

| Component | Responsibility and access |
| --- | --- |
| Agora.Build / Auth backend | Account/login/API authentication, integration-management metadata/workflows, API credential lifecycle, catalog and explicitly saved relay registrations. No private agent payloads, memory/vault bodies, user vault secrets, account decryption keys or endpoint private keys. |
| Agora.Build / Stoa | Meetings, voice/video, screen-sharing UI, room/media APIs and provider integration. Media uses its dedicated RTC transport, outside Station's R9 relay/storage path. |
| Station relay and storage modules | Tenant-private ciphertext storage/sync, signed membership records, sealed recovery material and opaque R9 transport. No endpoint keys or content decryption. |
| Station agent module | Validate Agora.Build/Auth-issued integration credentials; hold scoped R9 service keys; handle authorized chat, approvals, receipts/events and Discord operations. This module can read its permitted agent content. It receives no account K or automatic memory/vault/credential access. |
| Native Astation and direct R9 clients | Hold their protected device keys and decrypt authorized content. Native managers review/sign exact enrollment requests. |
| Atem host | Verify membership and operation scope, enforce control/receipts/approvals and execute host operations. |
| Discord / third-party callers | Receive content explicitly sent through their permitted integration; no implied access to the rest of the private account. |

"Stays on Station" defines the private server-side store. Authorized clients
still need plaintext while using data. Local caches, exports, backups and any
additional replica require explicit storage policy; this is not a promise that
Station is the only physical copy. Confidential synchronized content must be
encrypted. Encryption-off storage and retained old plaintext backups do not meet
that confidentiality guarantee; this design neither changes their mode nor
claims to erase old copies.

Auth's own authentication/provider credentials are distinct from user vault
secrets. The existing Agora Console connection uses Portal-managed provider
tokens and certificate APIs. Whether that provider integration meets the desired
custody rule needs separate review; do not silently move/delete credentials or
claim that all existing secret-handling paths already satisfy it.

### Self-hosted and shared deployments

Use the same Station server/package for both deployments:

- **Relay and encrypted storage:** the agent module is disabled by default.
  Native/direct R9 clients work without giving Station decryption authority.
- **Agent integrations enabled:** the administrator makes the module available;
  each account must separately authorize its integrations through a trusted
  native manager. Installing/enabling the module enrolls nobody and grants
  access to no account by itself.

Enabling an integration explicitly trusts the selected Station as a decrypting
endpoint for that integration's scoped agent content. An administrator who
controls that machine may read its plaintext/software service keys. Module,
process or container separation does not protect against the host administrator.
The relay/storage handlers remain opaque, but a Station running an authorized
agent integration must not be advertised as blind to that integration's content.

Friends sharing one Station keep separate accounts, roots, namespaces, API
credentials and service identities. Using the same server does not add users
to each other's trusted device lists. If the shared server's operator must
remain outside the content trust boundary, leave agent integrations disabled
for that account and use a native/direct R9 client, or an integration on another
trusted Station. Remote integration placement still needs supported routing and
Auth admission; no copied user refresh token or new trust bypass is implied.

The relay operator can observe necessary routing/signed-log metadata and traffic
size/timing, and can interrupt service. Moving to another Station does not reset
trust, enroll a device or automatically migrate private data. Self-hosted/shared
Auth-resource registration and migration need explicit support and validation.

### Component assignment

| Component | Owner | Responsibility |
| --- | --- | --- |
| Integrations management | Agora.Build / Portal | One UI/management API, catalog, permitted configuration metadata, creation/rotation/revoke workflows and Discord install coordination. Fetch private runtime details directly from the chosen Station; do not centralize private content or user vault secrets. |
| Identity, API credentials and delegated service login | Agora.Build / Auth | Native OIDC, API credential issuance/rotation/revocation, verification contract, registered resource audiences/scopes, service-to-account delegation/renewal and future public-app OAuth consent. |
| RTC and screen sharing | Agora.Build / Stoa | Voice/video/meeting/screen-sharing application and media APIs. Native platforms provide capture/client capabilities; Station is not the RTC application or media relay. |
| Native integration authorization | Astation | Show the selected Station endpoint, exact keys/account/root/targets/permissions/expiry; require fresh manager confirmation; sign/durably publish through the shared core. |
| Station API, including agent integrations | Station server, maintained on the Astation side | Existing encrypted routing/storage plus credential validation, protected scoped service keys, agent execution handlers, receipts/events and Discord runtime adapter. Apply management decisions from Agora.Build with explicit authenticated account binding; keep tenant/module state isolated. |
| Host authority and protocol | Atem | Verify membership, scope, expiry and possession; enforce host operations; supply the shared client/core and reviewed missing helpers/fixtures. |

## Architecture and privacy

```mermaid
flowchart LR
    subgraph Account[Agora.Build: accounts and setup]
      Portal[Integrations UI]
      Auth[Auth]
      Stoa[Stoa: RTC and screen sharing]
    end
    subgraph Station[Chosen Station server: one Station API]
      Relay[WebSocket relay: opaque R9]
      Store[Encrypted data and signed records]
      Agents[Optional agent module: scoped R9 client]
      DiscordAdapter[Discord adapter]
    end
    Native[Native Astation / direct R9 client] <-->|encrypted R9| Relay
    Relay <-->|encrypted R9| Atem[Atem host]
    Agents <-->|encrypted R9| Relay
    Custom[Custom API client] <-->|HTTPS / WSS| Agents
    Discord[Discord] <--> DiscordAdapter
    DiscordAdapter <--> Agents
    Portal --> Auth
    Portal -. managed configuration .-> Agents
    Auth -. credential validation contract .-> Agents
    Portal -. manager confirmation .-> Native
    Native -. signed membership / encrypted sync .-> Store
```

For native/direct clients, Station transports ciphertext and Atem handles the
R9 host endpoint. For integration API/Discord calls, Station's agent module is
the client endpoint and Atem remains the host endpoint. Decryption happens in
the authorized endpoint, never because a request passed through the relay.

Portal/Auth login grants account administration/routing visibility. Auth owns
API credential issuance; Station validates those credentials for its configured
resource and applies the granted account/integration scope. The
native-signed service membership grants particular agent operations. Neither
substitutes for the other. A token or management database change cannot widen
the service's host-verified R9 authority. Moving account/API authentication to
Agora.Build does not move native membership signing or Atem's cryptographic
verification to the login service.

Consent must name the selected Station and explain that its agent module reads
the integration's requests/results. Discord also receives content posted there.
This does not provide account-wide memory/vault/credential keys or encrypted
backup access. Keep direct/native channels separate from integration channels;
never terminate an existing native channel in the agent module.

Agora.Build stores the permitted integration-management metadata. Private labels
or runtime details that should remain on Station can be fetched directly from
its API rather than copied into the management database. A browser remains an explicitly authorized
endpoint under the companion model; putting a page on agora.build does not
grant the Portal backend private-data access.

Stoa and its RTC/screen-sharing functionality belong to Agora.Build. Keep media
room/session management and RTC provider transport separate from Station's
agent/data path. Native capture and authorized local RTC/RTM token generation
remain client capabilities; this design does not require an API request for
every locally generated media token.

Any enrolled native manager can confirm setup. After activation, Station and
Atem operate without that Mac online. A reachable Atem host remains necessary.

## One creation flow

1. Sign in to Agora.Build and choose Discord or Custom App / API.
2. Name the integration and select the R9 account/root, hosts, optional supported
   project/session constraints, operations and expiry. Default to minimal access.
   Proposed expiry default: 30 days; the agreed service maximum is 90 days.
3. Identify the selected Station endpoint. For API access, its agent module
   generates a dedicated service identity and retains its private key in
   protected server storage.
   A direct SDK client generates its own keys locally. Bind its public key and
   account/genesis to the authenticated setup request reviewed by the manager.
   Existing R9 has no separate service-enrollment possession-proof ceremony:
   the host first verifies possession through `sig_c` at channel admission.
   A claimed public key alone is not an active integration; do not describe
   the host-pairing ceremony as a service proof or invent another signed object.
4. A trusted native manager reviews and approves the exact request using fresh
   Touch ID, Face ID or the OS-supported password/passcode fallback. Bind the
   exact existing `add` or `set_roles` body, including the keys, principal,
   account/genesis, scopes, expiry and predecessor. Keep single-use setup context
   and endpoint-origin binding in the application workflow; they are not extra
   fields or a new service ceremony in R9. Verify the configured endpoint through
   TLS. A changed request or membership head invalidates the confirmation.
   Reuse the core's builders and verifier; missing transport/UI
   APIs require joint review, not new signatures.
5. Durably commit the signed authorization and provisioning state. Keep the
   integration pending until the relevant host has accepted its service identity.
   A committed log entry with an offline host is not proof that host is ready.
   The agent module verifies its own service `welcome` against the trusted
   chain/head including its membership entry; no new host acknowledgment is
   assumed.
6. Finish the connection through Agora.Build/Auth: issue/reveal a custom API
   credential, complete Discord setup automatically, or deliver public enrollment
   metadata to the SDK client. Station validates the API credential at runtime.
   Only an active authorization can expose usable agent access.

Account login alone can create a pending request, not activate it. When no
trusted manager is available, show pending authorization and the existing
recovery route. Do not replace native confirmation with a Portal checkbox.

Use one idempotent operation ID across the browser/native/Station workflow.
Persist exact approved bodies and progress, resume after disconnect/restart,
and reconcile CAS conflicts through the existing core. There is no transaction
spanning all services: use durable stages and compensating cleanup. A failed or
abandoned provisioning step must never expose a usable unapproved credential.

Suggested display states are Awaiting approval, Provisioning, Waiting for host,
Ready, Paused, Expired, Revoking and Revoked. Keep connection health separate
from authorization: an offline host does not become revoked, and an available
agent module does not imply an active service grant.

## Credentials, refresh and validation

| Credential | Issuer and storage | Validation and lifetime |
| --- | --- | --- |
| Native login access/refresh tokens | Auth; access in memory, rotating refresh in device-only protected storage. | Portal or Station checks its own registered audience/scope. Existing serialized refresh and fresh-auth rules apply. |
| Integration API credential | Agora.Build/Auth owns issuance, rotation, revocation and its protected credential records; the caller retains its issued bearer credential. Station does not mint a competing credential. | Station validates the supported Auth contract, selected Station audience/resource, account/integration binding, status, operation and expiry. Access never exceeds current signed R9 service authority. Send only in the Authorization header over HTTPS/WSS. |
| Service routing access token | Auth, through a proposed dedicated delegated service grant. | Station validates its own audience/scope and the authorized account binding. A short-lived routing token never replaces R9 proof. Exact registration/claims/issuance contract needs Auth review. |
| R9 service key and signed authorization | Service generates its key; an existing native manager signs its membership through the core. Private key stays at the agent module/connector or direct client. | Atem verifies the chain, scopes, expiry and possession. No manage/redelegation; at most 90 days, as in the existing service contract. |
| Discord bot/install credentials | Discord; retained only by the connector's secret store. | Discord credentials authenticate Discord interactions, not Atem access. Do not show/copy the shared Discord bot secret as a user's integration token. |

A caller can use an Agora.Build/Auth-issued bearer credential with Station API
without implementing R9. Auth must define whether that credential is a locally
verifiable signed token or an opaque key with a supported validation/exchange
contract; this draft does not invent a shipped format. Prefer local validation
of supported signed grants to avoid an Auth request for every operation. Specify
expiry, rotation/revocation propagation, stale-policy bounds and outage behavior
before enabling access. A raw key must not silently become a device identity.

Agora.Build manages credential rotation within existing authority; renewing or
expanding R9 authorization still needs native manager confirmation. The official
Discord integration need not reveal a user-visible API credential.
Renewal or narrowing through `set_roles` always fences the existing channel,
lease and queued work, even when it only extends expiry. Open a fresh channel
and reconcile uncertain receipts without replay; do not promise seamless renewal.
The verifier's 90-day check is relative to `signed_at`. The native signer must
use the current time, never forward-date it to stretch an authorization.

Short-lived service routing tokens may renew unattended within the approved
service delegation. Renewing a login token is not fresh user authentication
and cannot extend the signed service expiry. Account logout, disconnecting
Discord, token rotation and revoking R9 authorization are distinct actions;
the UI must say which action is being performed.

Auth/Station need an explicit service-to-account delegation contract before
unattended hosted access can ship. Current Station login maps a verified
`(issuer, subject)` to its account; a new service subject must not be treated as
the human subject, matched by email or supplied by an unsigned request field.
Agree how Auth attests the delegation and how Station validates it. Do not
copy a user's native refresh token to the agent module or invent
`client_credentials` support that Auth has not registered. This is an integration
contract gap, not a reason to change the R9 cryptographic identity model.

## Permissions and lifecycle

Use the same permissions for Discord and custom clients. R9 requires `view`,
which includes registry, chat/history, terminal subscription and receipt queries
within the selected target scope. A service grant cannot provide discovery-only
or chat-without-terminal-viewing access; consent must describe that whole read
capability. Agent module policy can further restrict what an API caller receives.
Sending prompts and answering approvals are optional operations. Interrupt/stop
and terminal input/resize are separate choices. File uploads, remote
process launch, vault access, device management and redelegation are not implied.
Map selections to the core's actual signed scope representation; do not invent
another scope language on the relay.

Session scopes bind actual process/session IDs and stop matching after agent
relaunch; never silently widen them. Project scopes use existing `h1.<kid>.`
hashes produced by a trusted native manager or host. Do not give account `K` to
the agent module to compute them. A locked host credential agent leaves project
comparison unavailable and affected sessions out of scope. Key rotation and
retained-generation behavior need explicit coverage before offering that filter.

Every request is limited by the intersection of the caller credential, current
integration policy and host-verified R9 authorization. An API token cannot widen
the service identity's grant. Prompt submission follows atomic acquire and
confirmed takeover; headless callers receive a conflict rather than silently
taking another client's control. Approval answers follow the existing lease-free
rules and exact pending request/rule identifiers.

Agora.Build/Auth can rotate an API credential without re-enrolling an unchanged
service key. Its supported validation/revocation contract must fence the selected
old credential across Station replicas/streams, with explicit overlap and stale
cache bounds. Lost credential-delivery responses require reconciliation and
explicit replacement, not secret replay from an idempotency cache. Raw bearer
secrets must not enter Station logs, management metadata or idempotency records.

Revocation has two layers. Agora.Build/Auth revokes API credentials/integrations;
Station applies the authenticated change to its streams and queued dispatch.
Define its acknowledgment/propagation guarantees before promising immediate
enforcement across offline replicas. Native managers also
publish signed service removal for host-side enforcement, including direct SDK
access. Show pending cryptographic removal until it propagates. The R9 relay
can delay an unseen removal; this proposal does not promise instantaneous
host revocation or change the agreed propagation model. Apply removal to all
credentials of that service; revoke one raw token without removing unrelated
credentials/integrations. Expiry cannot be postponed by reconnect or restart.

## API shape and real-time events

Expose one Station API with internally distinct route/authentication handlers:

| API surface | Authenticates | Handles |
| --- | --- | --- |
| Agora.Build account API | Auth-issued grants for that account resource. | Account/catalog/setup coordination; no private agent/data payloads. |
| Station API: transport/storage routes | Registered Station routing/storage grants and existing signed/encrypted object checks. | Ciphertext sync, signed records and opaque R9 transport. |
| Station API: agent/integration routes | Agora.Build/Auth-issued integration credentials for the selected Station resource. | Scoped plaintext agent operations through the module's native-authorized R9 service identity. No credential issuance or account-management API. |

One API origin does not make credentials interchangeable. An integration API
token cannot administer an account, access arbitrary encrypted storage or act
as R9 device proof. Agora.Build grants must not substitute for Station grants.
Keep token types/scopes and route admission explicit; no authentication fallback
between handlers.

Proposed Agora.Build management family: `/api/v1/integrations`. It owns permitted
integration metadata and create/configure/rotate/revoke workflows, with Auth
owning API credential issuance and the validation contract. Private runtime
configuration and agent payloads stay on the selected Station; agent operations
execute through Station API.
Native approval and service activation remain cryptographically verified
operations, not database fields the browser can set to true. Portal protects
cookie-based writes against CSRF.

Extend Station API with versioned sessions/messages/approvals/receipts/events
and authenticated runtime configuration/status ingress. Management belongs to
Agora.Build. Exact paths/errors are a follow-up contract;
existing opaque `/api/remote/v1` routes keep their semantics. New plaintext
agent routes must require the enabled, separately authorized agent module.
Register the selected Station audience/scopes before implementation; never
forward a Portal token to an arbitrary configured Station.

The module's route to Atem must preserve authenticated tenant binding, whether
implemented through existing WebSocket routing or reviewed in-process transport.
Packaging the module into Station does not settle Auth delegation or authorize
an unsigned account claim/internal admission bypass. Specify that binding and
recovery before enabling the module.

HTTP callers submit prompts with a stable idempotency key. Persist its binding
to integration/principal, full R9 target, payload and request ID before effects.
Duplicates query/return the original receipt; uncertain delivery never creates
a new prompt. Use the host's accepted/executing/completed/rejected/outcome_unknown
semantics. Approval races, local-input precedence, leases, reconnect recovery
and generation fences continue using the shared client state machines.

Use WebSocket initially, with optional authenticated fetch/SSE for clients that
only need response events. Preserve Markdown, typed tool/approval parts, message
IDs and receipt states; whole-message updates are sufficient. Bounded history
and event cursors must distinguish resync from missing history. Do not put
long-lived API tokens in URLs. Public browser clients use their own OAuth/backend
session flow; do not embed a shared integration secret into distributed web or
mobile code. Ordinary EventSource/browser WebSocket limitations need a supported
authenticated adapter, not a query-string credential workaround.

The agent module handles plaintext as an endpoint, so retention needs a
documented policy. Default to no persisted transcript/prompt/tool body. Keep
only the minimal encrypted operational state needed for receipts/recovery, with defined
retention; logs, metrics, Portal summaries and idempotency indexes exclude raw
tokens, keys and agent content. Detailed retention limits belong in the Station
API contract before implementation.

## Discord-specific behavior

Agora.Build owns the Connect Discord installation/consent/configuration workflow,
including OAuth state/callback handling and the selected guild/channel/actor
policy. Station owns runtime delivery and the adapter to its R9 client; private
agent content does not pass through the Portal backend for account management.
Verify Discord's documented ingress
authentication and deduplicate interaction IDs. Installation alone does not
authorize everyone in that server to operate Atem. Bind each invocation to the
approved integration and allowed Discord actor/channel; never accept a Discord
message's claimed Agora account or R9 identity.

Connector credentials use the same agent-operation layer as custom API calls.
An authenticated Discord approval command still needs the exact current typed
approval and permission; model-generated links/text never create an approval.
Formatting adapts to Discord's limits without changing receipt meaning or
silently losing content. Separate integrations cannot share an R9 identity,
conversation scope or authority just because they use the same global bot.

Self-hosted Discord installation needs an explicit application/bot provisioning
strategy. Never distribute an official shared bot secret to arbitrary Station
operators. Use deployment-specific Discord credentials or a separately reviewed
installation/routing design with truthful data-handling disclosure. Automatic
setup must not conceal central plaintext forwarding or shared credentials; this
deployment detail remains part of the Discord contract review.

## Implementation order and acceptance

1. Review the unified Station API admission/privacy contract, protected service
   storage, per-account activation and service-to-account Auth binding. Product
   runtime placement is Station; account/API authentication, management and
   Stoa/RTC belong to Agora.Build. Remaining API/security contracts need review.
   Retain separate Station registration and existing live R9 release gates;
   this design does not close them.
2. Implement one custom integration with native-approved service enrollment,
   Agora.Build/Auth credential issuance/validation and minimal Station runtime
   methods/events. Use the actual
   shared client/host, not a protocol replica. Native approval/control APIs and
   artifact gaps are handed to Atem; Astation does not edit Atem checkouts.
3. Prove a headless API client can read, submit and answer an approval with the
   original Mac offline. Exercise actual-host reconnect and replica failures.
4. Add Discord as a preset over that same authorization and operation layer.
5. Add public developer OAuth registration/consent when multi-user third-party
   products need it. Keep each user's grant in the same Integrations page.

Acceptance tests must include cross-account/host refusal; narrow operation scope;
wrong issuer/audience/service delegation; enrollment key/head substitution;
late/duplicate owner confirmation; crash between signing/publication/activation;
lost token response; expiry and token rotation across replicas; pending host;
Auth key rotation/outages and stale revocation/configuration caches;
revocation of a token versus a service; reconnect after durable prompt acceptance;
approval races; Discord actor/channel isolation and interaction replay; Mac-off
operation; two accounts sharing one Station without cross-account access; an
independently hosted Station; disabled/unenrolled-module refusals; cross-route
credential confusion; per-integration key isolation; direct/native channels
remaining opaque while an integration is active; and evidence that the relay/
storage handlers and Agora.Build backend receive no private plaintext or keys.

## Current shared-core constraints and review gaps

[Atem's service-path review](https://github.com/Agora-Build/Astation/issues/65#issuecomment-6376801806)
was checked against immutable host/core pin
`6526e1cf602f01ebc33893698c2b1d588c8f889e`. The
[contract](https://github.com/Agora-Build/Atem/blob/6526e1cf602f01ebc33893698c2b1d588c8f889e/designs/protocol/atem-session-v1.md)
and [bindings](https://github.com/Agora-Build/Atem/blob/6526e1cf602f01ebc33893698c2b1d588c8f889e/designs/protocol/atem-client-bindings.md)
remain authoritative. This review does not approve additional service authority
or request an R9 change.

- Services have no encryption key for push hints. The agent module receives
  approvals while attached; it cannot rely on native push delivery to wake it.
- Shipped bindings exclude `SoftwareKeyStore`. A hosted client needs its own
  protected key provider or the existing deferred-signature path. Typed service
  member/scope builders and a project-hash helper are absent; use the verifier's
  schema checks, never another wire/signature implementation. Station's Rust
  module should use the existing crate directly with protected per-integration
  keys; the FFI limitation remains relevant to external SDK clients. No new
  JVM/Node server runtime is required by this design.
- Atem reports missing service binding coverage for admission/welcome, scope
  refusals and expiry, plus host scenarios for approval/seen, session and host
  restrictions, live renewal/narrowing, grant revocation, K rotation and refusal
  as a held-host reconciler. Add these to the joint acceptance plan; ordinary
  native or Rust bot success is insufficient binding/platform evidence.
- Under the current contract a service with control can `revoke_grant` browser
  companions on a permitted host even without a corresponding selected operation.
  The agent module API need not expose that method, but this does not narrow host
  authority of the service key. Keep this capability visible in the owner/security
  review and require a focused regression before activation; no narrower host
  guarantee is claimed by this draft.
- Logs allow at most 1,024 entries and 256 members; renewals/removals consume
  entries and IDs are not reused. Capacity planning and truthful exhaustion
  handling are required. Automatic re-pair, compaction or rollover is not
  authorized by this proposal.
- Service channels expire with their grant, subject to record/byte limits;
  the native channel's fixed 24-hour lifetime does not apply. The agent module can
  voluntarily close and establish a fresh handshake using the existing
  protocol. Its connection/receipt-recovery policy still needs review; this
  draft chooses neither a new host lifetime nor a default reconnect interval.

## Review and assignment requests

| Owner | Needed before implementation |
| --- | --- |
| Agora.Build / Portal | Integration management UI/API, permitted metadata and Discord installation/consent; direct setup with chosen Station runtime without proxying/storing private content or user vault credentials. |
| Agora.Build / Auth | Account/API credential issuance/rotation/revocation and verification contract; exact Station resources/scopes, supported service delegation, local validation, revocation-cache and outage behavior. Native PKCE exists. |
| Agora.Build / Stoa | RTC/meeting/screen-sharing application, media APIs and provider integration, separate from Station's agent/data transport. |
| Astation native | Exact manager-confirmed service enrollment, trusted project-scope preparation and protected local state. |
| Station server / Astation team | Unified transport/storage/runtime handlers, Auth credential validation, protected per-integration R9 service keys, authenticated management-change application, receipt persistence, tenant/route isolation and Discord runtime delivery. No account/credential issuer or RTC application. |
| Atem | Confirm service/client operations against the current contract, provide agreed missing helpers/fixtures and review service conformance. No wire change is assumed. |

Station owns integrated transport/storage/runtime APIs; Agora.Build owns account
and API authentication, integration management and Stoa/RTC/screen sharing.
Native Astation owns manager approval; Atem owns host/core.
The user-requested consolidation resolves the extra public service/name, without
approving additional R9 authority, undecided expiry/retention policy or a change
to the existing live release gates. This document does not deploy/enable the
agent module, change trust or authorize a production rollout.

## References

- [Remote agent API design](protocol/remote-agent-api.md)
- [Current independent API implementation](../docs/remote-api.md)
- [Account integration and trust boundary](protocol/account-identity-integration.md)
- [Agora.Build login and separate resource grants](../docs/agora-build-login.md)
- [Unified identity](../docs/specs/2026-10-10-unified-agora-build-identity.md)
- Atem coordination: [#81](https://github.com/Agora-Build/Atem/issues/81)
- Shared contract: [Atem #80](https://github.com/Agora-Build/Atem/pull/80)
