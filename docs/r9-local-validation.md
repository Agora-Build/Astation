# Local r9 validation without production Auth

The configured native OIDC client and relay verifier accept loopback HTTP
origins. The fixture below exercises their normal authorization-code + PKCE,
ES256/JWKS, account registration and durable recovery routes. It uses ephemeral
test-account keys, one synthetic account per issuer run and an isolated
Postgres database. It does not implement production SSO or bypass device trust.

## Start the services

Use Node 20+, Rust, Swift/Xcode and a disposable local Postgres database. The
example issuer/resource ports must be free. Use a database created for this
test; do not point it at an existing Astation database.

From the repository root, run the issuer in its own terminal:

```sh
node scripts/r9-test-issuer.mjs
```

It binds only `127.0.0.1:58430` and prints public configuration, never tokens.
`R9_TEST_ISSUER_PORT` and `R9_TEST_RESOURCE` can change the ports. Its signing
key and account disappear on exit; existing test-account sessions will then
require a new login. The authorization page requires an explicit consent click;
codes are single-use, short-lived and bound to PKCE, client, callback and resource.
Refresh tokens rotate and cannot be reused. The fixture is never packaged or
deployed as an account service.

In another terminal, start the actual relay against your disposable database:

```sh
cd relay-server
DATABASE_URL=postgres://localhost/astation_r9_test \
ACCOUNT_OIDC_ISSUER=http://127.0.0.1:58430 \
ACCOUNT_OIDC_AUDIENCE=http://127.0.0.1:58431 \
ACCOUNT_OIDC_REQUIRED_SCOPE=astation.remote \
RELAY_BIND_IP=127.0.0.1 \
PORT=58431 cargo run
```

Configure only this test relay and synthetic issuer. Leave provider credentials
unset. Both services bind loopback only. `RELAY_BIND_IP` defaults to `0.0.0.0`
for deployed relays; set it explicitly for this local test.
With no Redis it is a single-replica test. Production replica/ACK tests
are separate. `/api/remote/v1/capabilities` must show durable recovery storage,
revision 9 and `push_ready: false`.

## Run the real HTTP integration

```sh
node --test scripts/tests/test-r9-test-issuer.mjs
cd native-remote
R9_TEST_ISSUER=http://127.0.0.1:58430 \
R9_TEST_RESOURCE=http://127.0.0.1:58431 \
swift test --filter AccountOIDCLoopbackTests
```

This test performs consent, PKCE exchange and refresh using the native production
client, authenticates a fresh relay key on a real WebSocket, registers it with
the OIDC access token, writes a genuinely signed genesis through the production
HTTP router and reads/verifies it from Postgres. Invalid login is refused.
No account token, identity or recovery checkpoint is loaded into the user's
Keychain. The test uses software keys and simulated browser consent, so it does
not establish the native owner-authentication or real app ceremony pass.

## Joint native app and Genie checklist

Use a dedicated macOS test user or a disposable Mac for the GUI ceremony.
A different app bundle alone is insufficient isolation: current Astation
identity/session/receipt files live in the user's shared `Application Support`
directory. Do not point the user's existing profile at the test account or
replace its saved pairing, recovery root or trust floors.

Launch the provisioned app in that isolated user with:

```sh
open --env ASTATION_RELAY_URL=http://127.0.0.1:58431 \
  --env ASTATION_ACCOUNT_ISSUER=http://127.0.0.1:58430 \
  --env ASTATION_ACCOUNT_CLIENT_ID=astation-local-r9 \
  --env ASTATION_ACCOUNT_RESOURCE=http://127.0.0.1:58431 \
  --env ASTATION_ACCOUNT_SCOPE=astation.remote \
  '/path/to/Astation Local.app'
```

Normal browser consent and Settings > Account login are required. Relay identity
registration must finish before recovery genesis can be stored. Save the
expanded Recovery Kit and complete the safety-code/Touch ID or password flow.
The original Agora RTC credential login is separate from this account login.

For Genie's disposable Atem profile, tunnel the relay through SSH so both ends
use the same loopback URL; do not expose the test issuer or send bearer tokens
over a public HTTP endpoint. For example, from the Mac:

```sh
ssh -N -R 127.0.0.1:58431:127.0.0.1:58431 Genie
```

The Atem agent owns its isolated profile and points it at
`http://127.0.0.1:58431`. This is a different relay from its production pairing;
the agent must manage that disposable pairing explicitly. Do not copy or move
the production host's keys or assume an existing production pairing applies.

1. Observe a verified r9 welcome and authoritative session list.
2. On disposable sessions only: terminal view, control, type/resize/paste, release
   and local input taking control back.
3. Submit one chat prompt; observe accepted/executing/final receipt and result.
4. Reconnect immediately after acceptance; query/catch up without another submit.
5. Answer one real approval; verify the terminal lease/deadline is unchanged.
6. Use a separately enrolled controller with independent keys while the Mac is
   offline; verify view, a prompt and an approval through its own relay channel.
7. Exercise host disconnect, room expiry and relay restart using the agreed
   host routing proof at Atem pin `83c0776` or its reviewed successor.

Step 7 remains a live validation gate: [Astation #64](https://github.com/Agora-Build/Astation/issues/64).
The shared contract and relay implementation are available. Controlled tests
exercise reconnect with no directory, ownerless expiry, durable Postgres
bindings, current-key verification and fencing at both replica queues.
See [the lifecycle evidence](../designs/protocol/r9-host-routing-lifecycle.md).
Fixture-side directory recreation is not a pass for this step.

Run those controlled checks against an isolated local Postgres instance:

```sh
cd relay-server
cargo test
RECOVERY_TEST_DATABASE_URL=postgres://astation_test@127.0.0.1:55439/postgres \
  cargo test remote_api -- --include-ignored --nocapture
```

Each Postgres case creates and removes only its own schema. The full relay run
passes 513 tests with 119 environment ignores; the remote API run executes all
47 cases without skips. Its replica transport is an injected bus with real
dispatchers and separate database pools. Real Redis replicas and the actual
Atem runtime still need the joint matrix; no mobile client is required for it.
Drain older relay revisions before admitting routes on an upgraded cluster.

Record test profile, source pins, account/host generations, results and failures
without credentials. Production login, real APNs/FCM and platform owner-auth
tests remain distinct. Push is follow-up work, not the joint r9 release gate.
Stop both services and remove only the disposable database after testing.
