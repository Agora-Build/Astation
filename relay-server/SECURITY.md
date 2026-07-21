# Station Relay Security Status

The relay server is not yet production-ready as an authorization boundary.
TLS at the reverse proxy, CORS, validation, and rate limiting are necessary but
do not replace application authentication.

## Implemented controls

- HTTPS/WSS is supported through the deployment reverse proxy.
- Auth grant attempts and general API requests are rate limited by client IP.
- Pairing rooms expire after 10 minutes when no Astation is connected.
- Atem messages carry a stable, sanitized `atem_id` envelope.
- The relay records a pending session claim and binds it to a room only after
  Astation returns an authenticated/granted response.
- Pairing/auth pages HTML-escape user-controlled values.
- Vault authorization checks granted sessions and the Astation room binding.

## Device authentication v2

The relay transports the v2 challenge and HMAC proof but does not know the device
session token. Astation is the verifier and must not register a relay Atem or
process its application messages until verification succeeds.

```text
Atem -> relay -> Astation: hello
Atem <- relay <- Astation: auth_required {challenge, astation_id, protocol=2}
Atem -> relay -> Astation: auth {session_id, atem_id, proof}
Atem <- relay <- Astation: authenticated
```

The relay observes the final Astation response to populate its short-lived
session verification cache. A session ID by itself is not device authentication.

## Production blockers

1. `role=astation` identity-room ownership is not authenticated. A separate
   per-installation relay-owner credential must be required before room creation
   or replacement.
2. Voice, LLM, and RTC session endpoints are not consistently protected by an
   authenticated device session.
3. Vault authorization still accepts a session identifier at the HTTP boundary;
   it must be tied to the v2 device proof or a derived short-lived API token.
4. Per-Atem disconnect and replacement cleanup must be connection-generation
   aware so an old socket cannot remove its replacement.
5. WebSocket connection admission and message size/rate limits need explicit
   production bounds.

Do not describe a deployment as production-ready until these items have tests
and the deployed configuration requires them.

## Deployment baseline

- Expose the service only through an HTTPS/WSS reverse proxy or tunnel.
- Do not publish the container port directly to the internet.
- Set a single explicit `CORS_ORIGIN`; never use `*` in production.
- Set `DATABASE_URL` for durable Vault storage.
- Keep secrets in the deployment secret store and out of URLs and logs.
- Use `RUST_LOG=info` or stricter in production.

See `../docs/specs/2026-07-21-device-authentication-v2.md` for the coordinated
Astation/Atem protocol, rollout order, and current LAN limitation.
