# Encrypted host policy review and native lifecycle

Reviewed Atem PR #100 at `ed0b45bad5db0a278c63efe8a464f12d4d548465`,
stacked on #98 at `04140840fc0cec4086072ab6326b7a1b46b25be4`.

The R9.8a format is accepted for integration. No critical format issue was
found in the reviewed contract, host storage/dispatch and shared tracker.
This is not release approval for the complete R9 stack or hosted execution.
The published binding suite does not exercise policy operations against its
test host; native binding and actual-host verification remain release gates.

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
