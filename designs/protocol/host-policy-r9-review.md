# Encrypted host policy review and native lifecycle

Reviewed Atem PR #100 at `ed0b45bad5db0a278c63efe8a464f12d4d548465`,
stacked on #98 at `04140840fc0cec4086072ab6326b7a1b46b25be4`.

The R9.8a format is accepted for integration. No critical format issue was
found in the reviewed contract, host storage/dispatch and shared tracker.
This is not release approval for the complete R9 stack or hosted execution.
The published binding suite does not exercise policy operations against its
test host; native binding and actual-host verification remain release gates.

## Shared service test scenarios

Reviewed `tests/r9_services_binary.rs` and the contract at #98's immutable
`04140840fc0cec4086072ab6326b7a1b46b25be4`. The following six existing
runtime scenarios are accepted as coverage to promote into shared fixtures:

1. Approval delivery and lease-free answers require the service's exact
   `approval` operation; a service's seen event cannot sign a native push ACK.
2. Host and session restrictions prevent admission or hide out-of-scope
   sessions, including receipt queries.
3. Renewal and narrowing fence the existing service channel, requiring fresh
   admission under the new scope and expiry.
4. Native browser-grant revocation fences that browser while an independent
   service remains usable.
5. Project scopes track retained K generations; unknown, foreign and dropped
   generations cannot match. The test's hash-table hook is test-only.
6. A service cannot reconcile a held host; reconciliation requires the
   managing native device.

This accepts the test coverage without changing wire formats or granting new
authority. The additional seventh test recording service-initiated browser
grant revocation is outside this acceptance and does not close the existing
browser-companion security review. Exact shared JSON fixtures and their
cross-platform execution still require review once published. Fixture
promotion does not block preparing the disposable host or adding the binding
policy tests. No main merge or hosted-execution release is approved here.

## Invariants

- Only a verified native manager sends policy operations, inside an admitted
  `atem-ch1` attachment. A relay, service, browser or plaintext message cannot
  establish policy authority or readiness.
- Save the account/issuer/selected Station/host intent before sending. Save
  each mutation's UUID, original expected revision and identity binding before
  its first transmission. Retries retain that body and use a fresh wire ID.
- A new attachment starts unconfirmed and reads the current policy. Retrying
  an uncertain mutation never creates a new mutation ID. A superseded or
  conflicting request requires review; reconnecting must not silently reverse
  another manager's decision.
- Only the shared core's bound, durable confirmation for an outstanding
  request can confirm a host. The platform also fences the account, selected
  Station, verified host pin, membership root/head and current attachment.
- Keep all reviewed hosts in the account-wide readiness calculation. Offline
  hosts, unverified replacements, uncertain writes, storage errors, timeouts
  and membership changes cannot count as confirmed.
- Persisting relay-only intent blocks direct agent operations immediately.
  Session-capable connections carry policy operations on the same encrypted
  native attachment as the registry, terminal and chat. Opening a second
  policy handshake concurrently violates the host's one-init-per-second
  bound; no extra handshake is needed to confirm policy. Both consumers
  lose readiness when that attachment ends, and a replacement reads policy
  again before counting as confirmed.
  An existing direct connection may open a restricted encrypted policy channel
  to migrate the host; it cannot carry terminal, chat or session operations.
  Close that connection after confirmation or bounded timeout. Only a fresh
  confirmation on the selected relay counts toward account readiness.
- Policy readiness and hosted execution admission are separate. The production
  execution gate stays closed until the real approval/enrollment/execution,
  revocation/reconnect/Mac-off/replica checks pass.

## Durability review

The host writes the whole policy and its mutation receipt through a pending
intent, rolls forward uncertain writes, and disallows direct links while a
pending or unreadable policy exists. A lost result never rolls back a durable
policy. If a crash loses a rename whose directory fsync failed, the client has
received no durable confirmation: it stays unready and reconciles on reconnect.
Neither an uncertain response nor the old plaintext ACK enables execution.

## Validation

The 2026-10-29 native check confirmed owner authentication and a seq7 R9
welcome, but a concurrent policy init received `close{reason:"busy"}`.
The host's one-init-per-second admission limit is working as specified.
The native adapter now shares the session attachment for policy operations.
A provisioned regression covers delayed owner confirmation, one handshake
for both consumers, and closing the old channel on membership refresh.
Restoring the separate policy path makes the regression fail. Exact account,
host, pairing, route and transport-generation changes prevent channel sharing.
The full provisioned suite passes 1,109 tests, with eight optional skips and
no failures.

Live validation then passed at 2026-10-29 05:33:22 UTC with provisioned native
source `dcd65848acb30b2fef730e35ce322ba09733ae5f` and actual host source
`a2cc6711117b79a73298c27baee337e25f9d87af`. After real user owner confirmation,
one native channel welcomed with local and host membership seq7. The exact
host/trust-generation-2 relay-only checkpoint is durably saved as completed
in the native journal. This closes the live policy-acknowledgment gate; it
does not enable hosted execution or replace the remaining API, approval,
revocation and availability checks. No new pairing or integration approval
was needed. The registered dev Station remains on the independent Volumetric
server with two replicas.

Source was read through GitHub at the immutable commit; selected Git blobs
were hash-verified. Atem reports eight actual-runtime scenarios / 114 checks
and successful core/binding CI at that commit. That upstream result is distinct
from local native integration testing. The Apple package's GitHub artifact
digest and clean source metadata were verified before consumption; no Atem
checkout was edited or built.

Native tests cover initial get/set, matching durable confirmation,
uncertainty, duplicate/late/foreign responses, reconnect with the original
mutation, superseded requests, another manager's change, direct migration,
revocation/re-pairing, offline hosts and failed local persistence. Refusal,
conflict and save failure close a direct migration immediately; silence closes
it at the monotonic deadline. Both paths preserve the pairing and saved intent.
The API suite continues to verify that production hosted execution is closed.

Approval and execution remain separate lifecycle steps. Native approval may
publish the reviewed service membership before every host is online or policy
ready; that publication grants no Station execution admission. The closed
production gate prevents service execution and Ready reports. Before opening
that gate, the real pipeline must establish the encrypted policy confirmation,
current service authority and host admission, then pass the documented negative
and Mac-off/replica checks. A cached native readiness indicator must never serve
as Station authority.
