# Existing account security on a new Station

Selecting a different Station changes the transport and OAuth resource. It does
not create a new account trust anchor, Recovery Kit, device identity or data key.
The native checkpoint remains account-scoped and authoritative for its pinned
genesis and signed history. Station storage and account login cannot create
membership or integration consent.

## Missing records

An authenticated `404 recovery_record_not_found` means the requested security
record is absent or inaccessible to this account. It must not be reported as a
temporary server outage or trigger an automatic trust reset. Other 404 responses,
authentication/permission failures and outages do not authorize publication.

In Integrations, an existing native setup with that response offers **Connect
Account Security to This Station**. The owner reviews the exact selected origin
and confirms locally with Touch ID/password. The app checks that its account and
Station selection remain current throughout the operation.

## Publication invariants

- Publish only the existing, independently verified signed log. Never generate a
  replacement genesis, re-sign historical entries or infer membership from OAuth.
- Read and compare the destination's entire prefix with the pinned local chain
  before writing. A different history, a frozen log or an outstanding conflicting
  membership operation requires review. If the destination is ahead, verify and
  durably commit its extension against the native anchor and recheck this manager
  before publishing. This also recovers a lost backup-commit reply after restart.
- Append the original entries in order with their predecessor hashes. Repeated
  entries are idempotent. An interrupted transfer resumes from its verified prefix;
  its progress cannot replace or truncate the native checkpoint.
- Read back the complete expected head before using the destination. A successful
  append response alone does not prove persistence. Partial publication does not
  make the UI ready for integration approval.
- If the current encrypted backup is absent, use the existing durable backup
  writer and fresh local signing confirmation to seal the same data keys for the
  same Recovery Kit. Plaintext keys and the kit secret never go to Station. No
  fallback occurs for authentication, availability or integrity errors.
- Existing revoked entries, pending evidence and origin-bound service approvals
  remain intact. Publication does not reapprove a revoked integration or authorize
  an integration on the new origin. Hosts still require the normal live route and
  cryptographic freshness checks.

This uses the existing R9 membership and backup endpoints. Atem needs no wire or
host implementation change. Hosts on a different Station still need an explicit
transport change and authenticated reconnection; copying their signed enrollment
does not move a running process or grant a service access to it.

## Relay-only intent

A saved relay-only restriction continues blocking direct connections after a
Station change. The UI offers **Use Selected Relay Only** to explicitly bind that
intent to the new origin, instead of offering to turn the old restriction off.
Only the host's matching durable encrypted acknowledgement marks it confirmed.
Hosted execution keeps its independent end-to-end release gate.

## Development server selection

Debug builds default to the dev Portal/Auth and built-in Station. Their General
page offers Dev Servers and Production Servers presets, plus an editable Portal
URL. A preset previews a matching Portal and built-in Station; Save Servers applies
the change through the existing sign-in invalidation path. It does not copy grants
or trust, trigger sign-in immediately or silently apply a different server.

Release builds default to production and show the Portal URL as read-only, without
the development preset control. Custom Stations remain available. Explicit operator
environment overrides stay read-only and disable the paired preset control.
