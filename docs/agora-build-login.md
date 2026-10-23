# agora.build login and Agora projects

Astation's account login uses agora.build OIDC, not the Agora Console OAuth
flow. Settings > Account contains one sign-in and account identity.
Recovery Kit and restore actions live under Settings > Security.
Agora Projects contains the linked Agora connection status, **Manage Agora
Connection...** (or **Connect Agora Account...**) and **Refresh Projects**.
**Refresh Projects** follows **Generate Token...** in the top row. The bottom
row combines connection status and the loaded-project count, with the
Manage/Connect button on the right. Saved-project and error details use that
same footer.
Settings > General groups the editable environment settings and direct
WebSocket addresses in one **Servers & Connections** block:

| Setting | Current default | Override |
| --- | --- | --- |
| Portal URL | `https://agora.build` | `ASTATION_PORTAL_URL` |
| Relay URL | `https://station.agora.build` | `ASTATION_RELAY_URL` |

Each field has a short description. **Save Servers** applies the account and
relay settings together; changing only the relay keeps the account signed in.
The read-only WebSocket details show direct Atem connections through this Mac,
the LAN or a VPN.

The menu's **Server Info** also shows the effective Portal URL alongside
WebSocket and Station. Click a URL to copy it. The current local test setup
keeps `https://dev.agora.build` as its saved Portal URL; the production default
applies when no saved setting or override is present.

Auth URL is derived by prefixing the portal host with `auth.`, preserving its
scheme and port: `https://dev.agora.build` uses `https://auth.dev.agora.build`,
and `https://agora.build` uses `https://auth.agora.build`. Portal and relay
login use this same issuer. The old separately saved Auth URL is ignored and
removed when saving servers, so it cannot pin login to a previous environment.
Developer environment/build overrides (`ASTATION_ACCOUNT_ISSUER` or
`AstationAccountIssuer`) remain available for separately hosted Auth services.
An IP-based loopback portal needs an explicit Auth override, allowing local
portal and Auth servers to use different ports.

The native OAuth client ID and Portal API resource stay internal, defaulting to
`astation` and `https://api.agora.build`. They are not shown or editable in
Settings. Saving servers preserves their configured values. Development builds
can override them with `ASTATION_ACCOUNT_CLIENT_ID` and
`ASTATION_PORTAL_RESOURCE`.

The menu-bar **Sign in to Agora.Build...** action starts browser sign-in
directly. While it is pending, the menu shows **Signing in to Agora.Build...**
and prevents duplicate attempts. After signing in, the account item opens
Settings > Account for account management.

The internal API resource remains the token audience used by the existing
project/certificate login grant; it does not add a token-generation API call.
It must match the registered Auth resource and Portal's `PORTAL_API_AUDIENCE`.
Portal/client/resource values use environment overrides, saved settings, build
configuration, then defaults. Auth uses an explicit environment/build override
or portal derivation. Overridden visible fields are read-only. The app uses
HTTPS base URLs, allowing HTTP only on explicit loopback development hosts.

Changing an environment signs out the active app account sessions and fences
pending logins, refreshes and project/certificate responses, and clears the
saved project credentials. Keychain storage
is isolated by portal, issuer, client ID and resource. Account tokens are never
sent to an old/new environment interchangeably, to the Agora BFF, or through
`credentialSync`. Device keys, paired Atems, trust records, Recovery Kit and
encrypted data are retained. Login does not enroll or verify devices.

## Using linked Agora projects

1. Choose **Sign in to Agora.Build...** from the menu bar, or sign in from
   Settings > Account, using the system browser.
2. Open **Agora Projects** and choose **Connect Agora Account...**. It opens `<portal>/account/`; connect
   the desired Agora account there, while signed in to the same agora.build
   account.
3. Return to Agora Projects and choose **Refresh Projects**. A connected Agora
   account's project names and App IDs populate the existing Projects UI.
4. Astation fetches a project's certificate when selecting it for media, using
   Token Tools, or revealing/copying its certificate. It verifies the returned
   project/App ID binding and caches the linked projects and certificates in
   the Data Protection Keychain (`WhenUnlockedThisDeviceOnly`), scoped to the
   portal, issuer, client, resource and account. It never logs certificates or
   stores them in preferences or ordinary project files.

### Local token generation and offline use

RTC and RTM tokens use the existing shared Atem token library on this Mac.
Creating a token does not call the portal when the project's certificate has
already been loaded. Custom App ID/certificate generation and token inspection
continue to work locally too. Portal also offers a server-side token API, but
the user chose local generation to avoid a network dependency per token.

Previously loaded credentials survive an app restart through the protected
Keychain cache. Astation restores them only for the same saved account and
environment, and shows the saved-project timestamp when online refresh is
unavailable. Select each desired project while online before using it offline;
an uncached certificate still needs an online fetch. Expired or interrupted
OIDC refresh does not turn cached service credentials into an account token:
local generation can continue, while online account/relay APIs still require a
valid, correctly scoped grant.

**Refresh Projects** updates the project list and selected project's certificate.
Removed/replaced projects are removed from the cache; a successful selected
certificate response replaces the old value, including a null certificate.
Signing out, changing environments, a disconnected Agora account, or a
definitive project-access refusal clears the cache. Offline operation cannot
learn about a server-side change until the next successful refresh. This cache
does not authorize device enrollment, recovery, remote control or r9 routing.

The portal holds and refreshes the upstream Agora connection. Connecting an
Agora account grants access to resources; it does not change the agora.build
account ID. A missing connection shows a connect prompt; an unavailable or
expired connection shows an error instead of falling back to direct Agora
login. Existing manually configured credentials remain available.

Previously consented legacy Agora service credentials are retained for the
existing Atem credential consumer. No new direct Agora login is offered by
Astation. Replacing that consumer with portal-scoped per-client grants belongs
to the Atem agent; an agora.build token must never masquerade as an Agora token.

## Confirmed API contract

Source reviewed on 2026-10-23:

- Auth `059c6d94b2985b60531b3e47445329407dd13e73`, `docs/integrating.md`.
- Portal `3fb16b2859f0eec164dfcb3b85c5a8bd163a27cf`, `docs/platform.md`,
  `scripts/serve.mjs`, `scripts/connections.mjs`.

| Call to configured portal | Required scope | Response |
| --- | --- | --- |
| `GET /api/connections` | `agora:projects` | `{agora:{ready,connect,connected,name?}}` |
| `GET /api/connections/agora/projects` | `agora:projects` | `{projects:[{projectId,appId,name,status}]}` |
| `POST /api/connections/agora/certificate`, JSON `{projectId}` | `agora:certificates` | `{projectId,appId,certificate}`; certificate can be null |
| `POST /api/connections/agora/token` (optional server API, not used for native token creation) | `agora:tokens` | Signs RTC/RTM tokens with the same pinned Atem library; certificate stays on Portal |

These APIs already accept bearer tokens. No new project API is requested.
Bearer requests use an ephemeral, cookie-free HTTP session with redirects
disabled, response limits and timeouts. Browser cookies are never imported.
401 requires sign-in; 403 indicates missing API permission; 5xx indicates an
unavailable service. Responses containing upstream credentials are not logged.

Auth discovery is fetched from the configured issuer and must match exactly.
Tokens require ES256 signatures, issuer, audience, client ID, expiry, requested
API scopes and ID-token nonce. The current account-ID format is
`^ab[0-9A-HJKMNP-TV-Z]{26}$`; the obsolete `acct_` form is rejected. Stored
legacy identities are not renamed or silently rebound.

## Auth/portal deployment requirements (handoff)

The maintainers must confirm the **actual deployed** native registration:

- Public client `astation`, PKCE S256, no embedded client secret.
- Native redirect registration `http://127.0.0.1/callback`, permitting random
  loopback ports as documented by Auth.
- Grants `authorization_code`, `refresh_token`; scopes `openid`, `profile`,
  `offline_access`, `agora:projects`, `agora:certificates`.
- Resource `https://api.agora.build`, also accepted by the portal; both Agora
  scopes present on this resource and allowed for Astation.
- Working portal Agora-connection deployment, including its OAuth callback and
  encrypted provider-token storage. No provider secret belongs in Astation.

The relay account/recovery API has a separate audience and grant. Its existing
`ASTATION_ACCOUNT_RESOURCE` / `ASTATION_ACCOUNT_SCOPE` and matching
`ACCOUNT_OIDC_ISSUER` / `ACCOUNT_OIDC_AUDIENCE` /
`ACCOUNT_OIDC_REQUIRED_SCOPE` remain explicit operator configuration. Astation
obtains that separate grant through the normal browser SSO after portal login
when the relay resource is configured; it checks that both subjects agree.
The grant is an internal authorization detail with no separate recovery
sign-in block. Security explains when online recovery is not configured.
Portal access tokens never authenticate relay recovery. The native client must be registered for the relay resource
and scope too. Fresh offline merge still requires verified `auth_time` in an
API token; an ID token's timestamp is not substituted.

Live unauthenticated checks confirmed dev discovery and portal auth config,
a 401 for an unsigned project request, and that native `astation` authorization
with the documented loopback/resource/scopes reaches the login interaction
without an OAuth registration error. They do not establish a completed
user login, linked-project access or deployed relay issuer configuration.
Subsequent user screenshots show a signed-in account and eight linked Agora
projects. Relay issuer configuration and the remaining live workflows still
need verification. No production merge,
deployment, trust migration or credential reset is part of this change.

## Validation

On 2026-10-23, the login baseline at `a14c9eb` passes the full app suite (995
tests, 15 environment skips), native library (123 tests, one opt-in integration
skip), and relay (513 tests, 119 environment ignores). Four account boundary
tests also pass with zero skips in the existing provisioned personal-team
XCTest host, including Keychain read/write/delete under a disposable service.
The loopback issuer's consent, signed-token/PKCE and refresh-rotation test
passes with the current account-ID format.

New regressions cover configurable URL precedence and validation, missing
Agora connections, audience/scope checks, malformed/legacy subjects,
certificate/project binding, project replies arriving after logout or server
changes, late certificate replies after project removal, and General layout
at the minimum window width.

The offline follow-up passes all 19 focused settings, project and Token Tools
tests with zero skips. It adds repeated local generation with no API requests,
offline restoration after restart, expired/interrupted OIDC refresh, certificate
rotation, unlink/removal invalidation, account/environment isolation and late
certificate responses after logout being unable to restore the cache.

The direct menu sign-in follow-up passes all 28 focused account, settings,
Token Tools and status-menu tests. With the Mac unlocked, the full app suite
passes 1,002 tests with 16 environment skips and zero failures. All five
account boundary tests pass without skips in the existing provisioned host,
including the protected offline-cache Keychain round trip. These controlled
tests do not replace the live user-login and deployment checks above.

The recovery UI cleanup passes 32 focused account-settings, linked-project and
recovery-coordinator tests with zero skips or failures. It removes the
standalone relay sign-in controls while retaining the normal sign-in's
separate relay grant and the Security recovery flows.

The two-field server settings follow-up passes the full app suite (1,004
tests, 16 environment skips, zero failures) and all five provisioned account
boundary tests without skips. Regressions cover portal-derived Auth URLs,
ignoring and clearing stale saved issuers, account/environment isolation,
custom domains and ports, explicit developer overrides for separate loopback
services, relay issuer consistency and the simplified General layout.

The production-default/Portal-menu follow-up passes 27 focused account,
settings, project and menu tests (two provisioned-host skips), plus all five
account boundary tests in the provisioned host without skips. The existing
saved-development-portal case confirms it retains its derived dev issuer.
