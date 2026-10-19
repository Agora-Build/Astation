# Review of Atem r9 draft at 016abe7

Historical review: [r5 at c685aba](remote-agent-api-atem-r5-review.md) closes
these findings and signs off the corrected contract for implementation.

Reviewed immutable pin: `016abe75ad6d04665067a82efa16e149f8c30faf`,
[Atem PR #80](https://github.com/Agora-Build/Atem/pull/80), 2026-10-19.
Compared with `ffe840d52d18aa655e15e44d44f53287ffde6522`; read the changed
documents, scenario expectations and vectors, including the runner changes.
The 66 downloaded documents/fixtures were checked against their Git blob
hashes. No Atem checkout was edited or built.

Status: **not signed off**. There are 59 r9 fixture files (7 vector files,
52 scenarios); Atem's runners deliberately report them NOT RUN. Independent
primitive checks pass, but the following contract gaps remain.

## Progress since the r3 review

R9.3 now fences live authorization and halts dispatch on failed writes,
including uncertain renames. R9.9 derives stages from signed original creation,
uses the signed expiry minus 15 seconds as the send cutoff, and separates the
120-second first-ingress skew bound. Pending seen survives relay restart,
delivery is acknowledged/retried, and matching binds the full approval identity.
The clear-error table agrees with the encrypted post-finish refusal rule.
These address the corresponding text findings; runtime conformance is pending.

[Atem's policy handoff](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6278073754)
and R9.5 record the user's two recovery decisions: **24 hours from each host's
first sight**, with manager approve/veto, and **replaceable kits**. With the
current kit, replacement is manager plus kit co-signature; without it,
replacement waits with approve/veto. The earlier questions about immediate
recovery versus a delay, and fixed versus replaceable R, are closed.

## 1. High: public-key backup sealing does not authenticate the restore root

[R9.5, kit and restore](https://github.com/Agora-Build/Atem/blob/016abe75ad6d04665067a82efa16e149f8c30faf/designs/protocol/atem-session-v1.md#L2228)
keeps R, account id and relay URL in the kit, then takes genesis and the host
keys from the relay's self-signed log. HPKE base mode allows **anyone** holding
the public kit key to seal a backup. Successful opening binds the supplied
account/genesis to that ciphertext; it does not establish who chose them.

A hostile relay can copy the genuine public recovery key into a substitute
genesis whose manager it controls, add a host key it controls, seal an
attacker-chosen K to that public recovery key, and sign the matching k_backup
entry with its substitute manager. The real R opens this backup. The substitute
host can also sign an accept head, satisfying the described freshness check.
All signatures/tags can verify while both the root and recovered K are wrong.
This is different from the r3 older-authentic-backup rollback finding.

Require an independently authenticated account/genesis anchor before accepting
the log's managers, host keys or backup hash. A genesis commitment saved with
the kit is one possible mechanism; the shared format must define the check.
Add a negative fixture with a wholly valid substitute chain and newly sealed
backup, rather than only changing AAD on an existing ciphertext.

Independent probe: used only public kit material to build/seal the substitute
chain and backup, then opened it with the real fixture kit and verified the
substitute host's signed transcript. This reproduces the cryptographic gap;
it does not claim an implemented r9 restore exists.

## 2. High: loss of the first persistence marker permits restart admission

This is a **remaining part of r3 finding 1**, narrowed by the new fixtures,
not a repeat of the now-correct live fencing behavior.
[R9.3](https://github.com/Agora-Build/Atem/blob/016abe75ad6d04665067a82efa16e149f8c30faf/designs/protocol/atem-session-v1.md#L1914)
detects uncertainty at restart only if membership.intent or membership.freeze
survived. The first write/fsync/rename can itself fail before that marker is
durable. Restart then has the old membership and no record of the observed
revocation or conflict. Rejecting pre-restart accepted work does not prevent
a newly connected revoked principal from acquiring fresh control.

The new
[freeze fault fixture, lines 121–132](https://github.com/Agora-Build/Atem/blob/016abe75ad6d04665067a82efa16e149f8c30faf/designs/protocol/fixtures/r9-chain-freeze-write-fault-stays-frozen-in-memory.json#L121)
explicitly uses disk=write_lost and expects frozen=false after restart. It
re-delivers the conflict afterward; an adversary need not do so. Restart has
therefore become an unfreeze path without re-pairing.

Require a durable indication established before accepting remote work that
survives a failure of the first membership/freeze write, or another explicit
restart reconciliation rule that prevents fresh admission on uncertain old
authority. Include intent-write failure and lost freeze marker scenarios with
no honest re-carriage, then attempt fresh hello/acquire/raw input. Do not rely
on persisting a new error marker after the same storage has failed.

## 3. Medium: a backup upload collision can prevent progress

[R9.5, writing a backup](https://github.com/Agora-Build/Atem/blob/016abe75ad6d04665067a82efa16e149f8c30faf/designs/protocol/atem-session-v1.md#L2285)
allocates newest logged blob_version + 1, uploads put-if-absent, and only then
appends the log entry. Manager A can occupy version 4 and crash before its
entry commits while the log still names version 3. Manager B's different
version-4 envelope gets 409. Re-reading the unchanged log and following the
specified retry chooses 4 again; that version may never be reused with other
bytes. An unrelated membership CAS loss after upload has the same problem.

Specify how occupied but uncommitted versions are skipped/reconciled without
requiring A to return or waiting for garbage collection. Preserve exact-byte
retry and the signed version floor. Add crash-before-CAS, envelope-409 and
unrelated-entry-CAS-loss fixtures. A small independent state trace repeats
the version-4 collision on three successive retries under the stated rule.

## 4. Medium: signed backup arrays have contradictory validation rules

[R9.2](https://github.com/Agora-Build/Atem/blob/016abe75ad6d04665067a82efa16e149f8c30faf/designs/protocol/atem-session-v1.md#L1796)
requires all arrays in signed bodies to be sorted ascending. R9.5 requires
kids to list the current key first, followed by retained generations. The
new signed KB7, KB8 and KB8_stale vectors use current-first order and violate
the generic sorted-array rule. A conforming strict parser rejects positive
KB7/KB8 even though their signatures and hashes reproduce.

Define which arrays are sets and which are ordered sequences, including the
backup envelope and membership k_backup record, and align fixtures/parser.
Preserve current-first semantics rather than sorting away the active key.

## New user choice: restore without a trusted reachable checkpoint

R9.5 now allows an unconfirmed restore to publish recovery_add when no host
answers. Its residual-risk paragraph says that publishing on a stale head
conflicts with the existing chain and freezes hosts, requiring re-pairing.
The new restore fixture explicitly expects that unconfirmed publication.
This availability tradeoff was not settled by the 24-hour/kit-replacement
decisions. Whether to wait before publishing or permit this fallback is with
the user; no decision is inferred or implemented. This question is separate
from the mandatory root-authentication correction above.

## Validation and implementation gate

Independent checks of the pinned examples pass **232 Python assertions**
(cryptography, PyNaCl, RFC 8785) and **28 Swift CryptoKit assertions**.
They include both kit derivations, Ed25519-to-X25519 correspondence, all three
backup opens and wrong-kit refusal, deterministic HPKE seal reproduction,
new membership/kit co-signatures, channel transcripts and push signatures.
The substitute-root and upload-collision probes reproduce the gaps above;
the marker-loss and array-order checks inspect the actual published fixtures.

These are primitive/example checks and small independent probes, not a run of
the 52 protocol scenarios, complete parser/effect conformance, Kotlin/WASM
conformance or security sign-off. The shared core, host and binding artifacts
remain Atem-owned and unavailable for Astation integration. PR #58 retains
gated readiness and isolated delivery policy; no r9 admission or provider
dispatch is enabled. PR #60's hello retry remains separate. No merge/deploy,
pairing, recovery, live trust change or verification bypass was performed.
