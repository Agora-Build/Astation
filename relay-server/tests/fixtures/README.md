# Push provider test key

`fcm-test-key.pem` is a public, generated test fixture with no association with
Google, Firebase or any account. Never configure a provider with this key.
Tests use it only to verify locally generated OAuth assertions and HTTP requests
through an injected transport; they never contact a provider.

# Auth Station conformance fixtures

`auth-station-tokens.json` is copied byte for byte from Agora-Build/Auth
`tests/fixtures/station-tokens/vectors.json` at
`d7de4416e74f2fcc85dcf4befa0a6bd8ad9ffb64` (PR #9).
It contains public test keys and 42 signed test tokens, never production
credentials. The verifier uses the fixture's recorded clock and offline JWKS.
All verdicts, error codes, returned principals/scopes and R9 key fingerprints
must match the Auth contract. Update the pin and fixture together after review.
