# Push provider test key

`fcm-test-key.pem` is a public, generated test fixture with no association with
Google, Firebase or any account. Never configure a provider with this key.
Tests use it only to verify locally generated OAuth assertions and HTTP requests
through an injected transport; they never contact a provider.
