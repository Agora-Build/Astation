# Independent agent API readiness

The remote API is being built for native/mobile Astation and scoped bots that
connect to the original Atem host without a running Mac. It uses the shared
`atem-client` and the jointly reviewed r9 contract. The relay transports
encrypted messages; it does not answer agent operations itself.

## Implemented on this branch

`GET /api/remote/v1/capabilities` is a public, non-sensitive discovery endpoint.
It returns HTTP 200 with `Cache-Control: no-store` and:

```json
{
  "api": "atem-remote",
  "version": 1,
  "status": "not_ready",
  "admission_enabled": false,
  "required_session_revision": 9,
  "supported_session_revisions": [],
  "transports": [],
  "blocked_by": [
    "r9_contract_conformance",
    "shared_client_core",
    "membership_admission"
  ]
}
```

This reports implementation readiness, independently of `/health` and the
Mac's existing local API. Requiring revision 9 does not mean r9 is implemented.
Clients must check `admission_enabled` and the supported revisions/transports
before attempting enrollment or an agent connection. The response carries no
account, device, session, presence, token or provider-configuration data. It is
discovery only, never proof of identity or permission.

Other unimplemented paths under `/api/remote/v1` return HTTP 503 with error
code `remote_api_unavailable`, `admission_enabled: false` and `no-store`.
An account token, local Mac bearer token or body claiming verification does
not enable these routes. Unsupported methods on an implemented route return
the router's HTTP 405. No r8 or plaintext fallback is provided here. Existing
relay, pairing and Mac-local r8 operations retain their own routes.

With a local relay running on its default port:

```sh
curl -i http://127.0.0.1:3000/api/remote/v1/capabilities
```

This endpoint is not deployed until this branch is merged and deployed.

## Notification policy foundation

`relay-server/src/approval_escalation.rs` evaluates a delivery stage using
explicit time and lifecycle inputs, without an app or external provider:

- Initial desktop OS notice when no desktop is connected; presence only
  affects routing and never supplies authorization.
- Mobile at original creation plus 60 seconds, or immediately if opted in;
  an authenticated active-user seen suppresses mobile without resolving it.
- Optional desktop reminder at 60 seconds; delivered stages are separate
  so an initial desktop notice does not consume a mobile notice.
- Known resolution, revoked authority or an already delivered stage prevents
  another provider attempt. Changing mobile preferences cannot resend it.
- The delivery cutoff is original expiry minus a supplied margin. It stops
  provider delivery without expiring an actionable approval card.

The policy takes original signed times, not a new relay receipt time; late
admission, restart and retry cannot postpone the 60-second deadline. The
margin remains an input; the signed-off r9 contract at `c685aba` specifies
15 seconds and agrees on the original-creation deadlines. Authenticated
lifecycle/shared-core integration still precedes ingress/provider wiring.

This module is not an authenticated ingress, durable outbox, job claimant,
retry scheduler or provider dispatcher. Its inputs must come from validated,
durable lifecycle records; a future worker must recheck current membership,
recipient key/token generation, resolution, seen and expiry before each
attempt. Per-recipient/stage receipts and claims need shared durable storage
across relay replicas. External provider delivery remains best effort; a
race after submission can produce a late notification, whose tap fetches the
current authoritative approval.

## Verification without phone apps

```sh
cd relay-server
cargo test remote_api
cargo test approval_escalation
```

These tests cover the actual discovery/gated routing and deterministic policy,
including exact boundaries, late admission/restart, preference changes,
resolution/revocation and delivery-margin behavior. They do not claim r9
channel, enrollment, durable provider delivery or mobile OS conformance.

The r9 contract is signed off for implementation at
`c685abab92535b167f5f2658c814f0f72541d9a1`; see the
[review and remaining gates](../designs/protocol/remote-agent-api-atem-r5-review.md).
The remaining native/service operations, scoped Discord integration, signed
membership/K-backup storage and sealed push use the Atem-owned shared core
once its tested artifacts are available. Full testing uses real independent
controller/service keys and fake providers with the Mac off, as specified in the
[implementation plan](../designs/protocol/remote-agent-api.md). Real APNs/FCM,
notification extensions and platform owner authentication are separate checks.
