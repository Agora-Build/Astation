# Review and implementation sign-off at c685aba

Reviewed immutable Atem PR #80 pin
`c685abab92535b167f5f2658c814f0f72541d9a1`, compared with `016abe7`,
2026-10-19. Read the changed contract, response, schema and fixture files;
verified all 74 downloaded document/fixture Git blob hashes. No Atem checkout
was edited or built.

Status: **signed off for contract implementation**. No critical or high
severity issue remains from this review. This supersedes the r4 blockers at
`016abe7`; it does not enable remote admission or satisfy the runtime security
gate in section 9. Atem may build the shared core and host against this pin;
Astation may build its agreed platform and relay integration.

## Findings resolved

| Previous finding | Resolution in this pin |
| --- | --- |
| Restore could accept a substitute genesis | The offline kit independently carries account_id and genesis_hash, bound to R by kit_tag. Restore checks the tag and genesis before trusting log managers, hosts or backups. SUB1-SUB3 remain cryptographically valid and decryptable, but fail the independent root check. Altering the kit's root fails its tag. |
| Lost first intent/freeze write reopened access after restart | A bounded carriage record is durable before evaluation. Replay applies a removal or conflict even when a later intent/state/freeze write was lost. An observed fault is separately recorded; a fault record or unreconcilable carriage holds remote admission until an authenticated current native manager reconciles. A known conflict remains frozen and cannot be cleared by this reconciliation. |
| Occupied backup version caused an endless 409 retry | Allocation advances above committed, locally uploaded and reported max_occupied versions. An unrelated log CAS loss keeps the envelope and rebuilds only its entry; a newer committed backup supersedes the orphan. The relay bound limits allocation jumps. Uncommitted envelopes remain untrusted. |
| Sorted arrays contradicted current-first key generations | Signed sets are sorted and duplicate-free; kids/keys are ordered sequences, current first. The positive KB7/KB8 vectors retain their meaning and bytes. |

The new scenarios cover substitute roots, modified kit bindings, unavailable
or lagging host heads, lost carriage/intent/freeze writes, recorded faults
followed by crashes, occupied versions and repeated collisions. I found no
new blocking contract issue in the changed text and expectations.

## Confirmed Astation obligations

- Accept the expanded Recovery Kit format: R, account_id, genesis_hash,
  kit_tag and relay URL. Generate it from the committed genesis; bind a
  replacement to the same genesis. Old kits lacking this anchor must be
  re-issued through the agreed current-kit replacement flow, never inferred
  from the relay during restore.
- Record the user's option A: without a trusted reachable host-signed head,
  restore waits. It stores no K as current, signs/publishes no recovery_add,
  rotates nothing, and explains how to resume. The earlier unconfirmed
  restore question is closed.
- Record option 2: a plain crash replays durable carriage and resumes; a
  recorded fault or unreconcilable carriage holds access. Reconnect an
  eligible manager for reconciliation; services/view-only devices wait.
  Do not confuse this recoverable held state with a frozen account.
- Retain the agreed 24-hour host-clock recovery wait/approve/veto, replaceable
  kits, five-minute routine owner-auth reuse with fresh trust-edit approval,
  unchanged device IDs, creation-based push with a 15-second send margin,
  active-user seen and r8 operation/lease semantics.
- Relay storage preserves exact signed bytes, bounded CAS suffixes and
  put-if-absent backups with max_occupied; transport or relay assertions never
  supply endpoint identity, account trust, recovered K or agent authorization.

Accepted residual risks remain explicit: eventual propagation of an unseen
revocation; storage losing acknowledged durable writes; restoration of an
older pairing directory; and the documented recovery-notification suppression
case. These user-approved limits are not new implementation guarantees.

## Validation and remaining gates

- **274 independent Python assertions** pass: all seven vector files,
  signatures/hashes, channel and push primitives, both kit tags and modified
  bindings, the substitute-chain backup and independent root mismatch,
  correct-kit rejection of bad ciphertext, and ordered backup generation lists.
- **41 Swift CryptoKit assertions** pass: channel/HPKE/recovery examples,
  both kit tags and modified bindings, substitute backup opening plus root
  mismatch, and bad ciphertext refusal.
- All **69 fixture files** parse (7 vectors, 62 scenarios); **148 symbolic
  hash/vector references** resolve. A small independent allocation probe
  progresses through versions 4, 5 and 7 instead of repeating version 4.

These are primitive/example checks and static scenario review, not an
execution of the 62 host/client/relay scenarios. Atem's runner still reports
r9 NOT RUN. Full shared-core parser/effect conformance, Swift/Kotlin/WASM
bindings, fault injection at actual persistence/input boundaries and the
multi-device/Mac-off matrix must pass before remote admission. Real platform
owner authentication and APNs/FCM delivery need their own checks.

This sign-off authorizes the agreed implementation work, not a production
merge, deployment, live recovery or trust change. Astation PR #58's public
capabilities endpoint continues to report not_ready/admission_enabled=false.
