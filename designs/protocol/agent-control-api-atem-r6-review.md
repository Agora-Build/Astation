# Astation r6 review: implemented r8 contract confirmation

Reviewed 2026-10-18. Source: [Atem PR #78](https://github.com/Agora-Build/Atem/pull/78),
implementation and fixture pin `10e089a3723352975c17b6efd1b9e2d88a05857e`.
The PR head checked during review was
`2591ec0517c304a2f9043c4953af4f9429af8a61`; its only change after that pin
updates the two handoff documents to name `10e089a`. The code, contract and
fixtures are identical at both commits.

**All four requested contract edits are confirmed. No blocking contract
findings remain for the current paired-native mode; Atem may merge #78.**
This confirmation extends the [r5 design sign-off](agent-control-api-atem-r5-review.md).
It does not establish Swift r8 conformance or joint live acceptance. Astation
PR #56 and the installed local app still use r7.3. Atem r8 refuses r7 peers,
so the client and host need a coordinated rollout.

Merged-pin update (2026-10-18): Atem #78 merged at `4f87bab1289848cb6a0da5707d2e7830eb5c057d`.
The contract and complete fixture set match this review byte for byte.
Astation's [r8 implementation](r9-client.md) now replaces the historical
r7.3 client mentioned in the review. The four decisions remain confirmed.

## Confirmed decisions

1. **Failed revocation write: keep the authenticated link open, without
   admission.** A valid r8 `hello` gets no `welcome`; subsequent session,
   terminal and chat requests get their family's `busy` refusal. The link
   grants no attachment authority, lease or queued dispatch. Terminal writes
   remain fenced at the write boundary until restart. The client must bound
   its handshake wait, leave controls disabled and avoid a retry loop; silence
   alone is not evidence of a journal failure. A received halted-journal
   refusal can tell the user to restart Atem. Section I.4's inability to
   persist even the refusal remains distinct: close without replying.
2. **Binding-free chat close: sender's own view only.** Accept it only on
   the authenticated connection and remove the conversation only when its
   owner equals that connection's current attachment. A supplied binding
   retains the ordinary read checks. Closing a view does not stop the agent,
   cancel accepted work, release another controller's lease or affect another
   attachment's view. Astation should continue sending a binding when it has
   one; conversation IDs never confer authority.
3. **History rate limit: follow the fixture.** Count up to eight valid
   `history` requests per second per conversation. Malformed selectors or
   fields returning `invalid_request` do not consume that budget; each gets
   one sequenced error on the sender's current open conversation, with its
   `page_id` only when valid. The fixture's twelve invalid requests followed
   by one valid request in the same instant is accepted behavior. This is a
   page-work budget, not an exemption from transport/frame/queue limits or a
   promise to answer unauthenticated traffic. Foreign conversations must not
   gain a sequence or disclose state. Valid requests with stale continuation
   tokens can still consume the budget; `invalid_request` and `stale_target`
   are different cases. Align any remaining all-requests wording with this
   decision.
4. **Opaque IDs: omit an unrepresentable result, preserve the receipt.** A
   completed prompt whose turn or user-message ID is outside 1-128 ASCII
   bytes of `[A-Za-z0-9._:-]` completes without `receipt.result`. Never
   sanitize, truncate or invent a replacement ID. The durable receipt state
   and detail remain authoritative; absence of result is unavailable
   correlation, not failed execution and never a reason to resend. Retention
   eviction of a valid user-message ID does not justify omission. An invalid
   reply ID is omitted from the reply list and makes coverage partial, as
   note 13 specifies. Current UUID-based Claude/Codex adapters avoid this
   narrowing.

The halted-link `busy` expectation is step **14** with one-based counting in
the pinned fixture (step 12 asserts the halted state). The handoff's step-12
reference is a nonblocking documentation correction.

## Fixture and source review

Compared the exact fixture blobs with the signed-off `f9fa57a` snapshot.
The five deleted r7 approval scenarios have their r8 replacements; the new
takeover and close-reason scenarios agree with lease-free answers. The
holder-deadline fixture now expects both registry changes at expiry, and the
hello fixture advertises all nine features. The second-hello and registry
fixtures carry r8 admission fields. No other scenario changed.

Inspected the host's admission and journal-halt checks, PTY write admission,
binding-free close forwarding and conversation-owner check, history field
validation before the rate counter, and completed-result ID validation. The
existing Rust tests cover foreign-close refusal, history budget boundaries,
invalid result IDs and halted queued terminal writes. These tests were read,
not executed by Astation.

Static validation passed for all **72 scenarios** (65 host, seven client),
including **47 r8 scenarios**: JSON duplicate-key rejection, filename/name
and revision checks, capture/reference order, the replaced-fixture list,
nine-feature welcome, twelve consecutive invalid-history errors and the
following valid page. All 135 downloaded source files match their recorded
sizes and SHA-256 hashes.

| Source at `10e089a` | SHA-256 |
| --- | --- |
| `atem-session-v1.md` | `61c02f789fdaf2c72710f975150f196e8c6b6979a6a6a3cc51e921ecbf1680c9` |
| `fixtures/schema.md` | `45611ced96ec4ab053b85ff0af490e881af854778f8789bd22e549e450686da2` |

Atem reports 72/72 core scenarios passing with both journals and real-runtime
coverage of 25 passing / 40 not run / zero failing host scenarios. Those are
the host owner's results, not independently executed Astation conformance.
No Atem checkout was edited or built. Swift r8 conformance and joint live
tests are **NOT RUN**.

## Integration and remaining gates

Pin implementation to `10e089a` until #78 merges, then record its actual
merge SHA and verify the contract/fixture hashes before repinning. A merge
SHA is not known before merge and need not equal the implementation pin.

Astation must implement mandatory revision/features admission; shared
native/API atomic Send and confirmed takeover; lease-free approval answers;
receipt results; sequenced whole-message history, history_end and coverage;
and the replacement fixtures. Retain the existing one-tap lease-free revoke
and offered Codex/Claude Always allow rules. Native/API ownership, renewal,
release, delayed replies, disconnect recovery and approval races still need
their client and joint tests before shipping.

The handoff's two known gaps are recorded rather than counted as passing:
recovered approval answers can produce a later rejected receipt instead of
an admission-time stale_target (no second agent decision), and another
attachment can reuse a conversation ID without explicitly closing the prior
owner's view. The latter must be fixed and tested before multi-attachment
access is enabled. Neither expands the current one-link runtime's authority.

The relay remains a router, never an identity, permission or encryption
authority. Account-wide membership, multiple native devices, browsers,
freshness proofs, E2EE and host push ingress remain behind section 9 and
their separate acceptance tests.
