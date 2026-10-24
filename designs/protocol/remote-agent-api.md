# Remote agent API for independent Astation clients

## Implementation status, 2026-10-21

Native direct and identity-relay sockets now use the shared encrypted r9
channel for session, terminal, chat and the local API. The plaintext session
handshake, obsolete fixtures and unused browser protocol replica are removed.
An unsupported host has no r8 fallback. The shared verifier's welcome is the
only way to establish presentation authority.

Independent clients use their own outbound authenticated WebSocket at
`/api/remote/v1/channels?genesis=...&host=...`, without a running Mac.
`AstationRemote.RemoteRelayClient` supplies the native transport. The relay
binds isolated handles to the exact outbound host socket and preserves inner
frame bytes. Ordered bounded queues and acknowledged replica delivery close
the channel on uncertain delivery, without ciphertext replay. The host alone
verifies device membership, proof of possession, scope and permissions.

A membership update from an authenticated channel stops operations until the
native coordinator fetches and verifies the signed chain, durably commits it,
and opens a fresh channel. Same-chain heads already held do not cause a new
handshake. A removed device cannot reconnect; active view-only native members
need no manage role to read sessions. Routine signing allows less than five
minutes of foreground owner-confirmation reuse; background, lock and sleep
clear it. Membership signatures always need fresh body-bound confirmation.

Controlled tests cover two independent clients with the Mac absent, exact raw
bytes, foreign-account refusal, host-generation isolation, bounded queues,
peer-close behavior and both replica dispatchers with lost ACKs. A real
WebSocket test performs P-256 native proof, host-signature verification,
encrypted welcome/registry and ciphertext replay refusal using the shared
crate. This is not a live Claude/Codex or mobile-platform conformance claim.
See [API usage](../../docs/remote-api.md), [r9 lifecycle](r9-client.md) and
[coordination status](../../docs/github-coordination.md).

The user deferred unavailable auth.agora.build. Code and controlled tests
continue, while production account registration/configuration, deployment and
live validation remain pending. The implementation does not introduce another
storage-authentication rule or legacy AGORA_ACCOUNT_* configuration. Durable
sealed push/provider integration and mobile/service platform validation remain
follow-up work; push does not block the joint r9 release. The complete provisioned
live ceremony and host reconnect lifecycle remain release checks. A
[validated local OIDC/relay path](../../docs/r9-local-validation.md) supports
controlled testing without production Auth. Main merges deploy
production and need user approval; neither Astation #58 nor Atem #89 is merged
by this work.

## Durable membership and recovery

The Apple client package and relay shared crate are pinned to Atem
`83c0776d21fa35c656eefaee25edd03cbbd203ee`, the final R9.7b host-route
delivery. It retains #93's durable MembershipLog binding API. The
[host-route review](remote-agent-api-host-route-review.md) records the
corrected contract, completed runtime execution and package verification.
Astation consumes the shared libraries and does not edit/build the Atem host
or its FFI packages. See [artifact consumption](../../docs/atem-client-artifacts.md).

Native checkpoints retain shared `stored_json` snapshots alongside each
writer's exact prepared state. Load with independently saved account/genesis
anchors and immediately commit before effects. Membership changes and clock
advances commit before dependent actions. Uncertain persistence halts account
operations; restart never discards recorded waits, approvals, vetoes or freezes.
The OS boot-session ID and periodic/background/sleep checkpoints retain
same-boot progress without trusting wall-clock jumps. Device-only Keychain
storage excludes these records from backups. Restore refetches the signed
chain and requires a fresh host-signed challenge after restart; a saved state
is not a new host freshness proof. See [Recovery Kit v2](../recovery-kit-v2.md).

## Sources and coordination

The jointly accepted protocol is in [Atem PR #80](https://github.com/Agora-Build/Atem/pull/80),
`designs/protocol/remote-agent-api-atem.md`, `designs/account-trust.md` and the
r9 appendix/fixtures. The [r5 review](remote-agent-api-atem-r5-review.md) signs
off contract `c685abab92535b167f5f2658c814f0f72541d9a1` for implementation.
Later implementation/artifact reviews and fixes are recorded in Git history,
the [eaaadc2 review](remote-agent-api-eaaadc2-review.md), the
[envelope review](remote-agent-api-channel-envelope-review.md) and #93.
Superseded review findings are not current blockers.

Read Atem memory and handoff vault `v-8ut37j7X` first, then linked GitHub
updates, every three minutes during active coordination. [Atem #81](https://github.com/Agora-Build/Atem/issues/81)
contains handoffs, answers, status and questions; PR #80 owns contract changes
and reviews. New topics get linked issues/PRs. The user does not carry messages
between agents. Bring new product/security choices to the user before posting
a decision. See the [coordination rules](../../docs/github-coordination.md).

## Product outcome and ownership

Mobile/native Astation and scoped bots operate the original `atem agent launch`
process whether Mac Astation is online, sleeping or offline. Each client has
its own device key, encrypted host channel and attachment. The host must be
running and reachable; no request is forwarded through a Mac or its local API.
Multiple authorized clients can view a session concurrently.

| Owner | Responsibility |
| --- | --- |
| Atem | Shared signed formats, r9/fixtures, `atem-client`, host admission, process/provider adapters, authoritative sessions/chat/approvals/receipts, durable membership fences and control. |
| Astation native | Platform key storage and owner authentication, account setup/Recovery Kit, enrollment/removal/service UI, bindings/transport/storage adapters, rich chat and approval UI, notification registration/decryption/seen detection. |
| Astation relay | Store exact signed membership and encrypted records, bounded encrypted transport, routing/presence, durable notification jobs, APNs/FCM provider delivery. |
| User | New product/security choices; explicit enrollment/recovery/removal confirmation. |

Atem owns `crates/atem-client`: sans-I/O Rust log verifier, channel in both
roles, session/lease/receipt/chat state machines, builders/verifiers and the
fixture runner. Consume its UniFFI Swift/Kotlin and WASM/JS bindings. Key signing
is a platform effect; networking, protected keys, persistence and UI remain
adapters. Do not duplicate the cryptographic protocol or host authority in
Swift, a bot gateway or the relay.

## Trust and identities

Pair and verify a host once with a trusted native manager. The ceremony binds
account/genesis, host identity/trust generation and the independent host
channel key. Every other native client enrolls its own keys through the signed
membership log. Login, shared data storage, relay rooms and hostnames are not
membership or proof of endpoint identity.

| Kind | Authority |
| --- | --- |
| Native | Log member with its own pinned authentication and encryption keys; view/control/manage roles are distinct. |
| Service | Manager-enrolled identity with signed host/project/session/operation scope and mandatory expiry, at most 90 days; no manage or redelegation. |
| Browser | Native-approved, non-transitive QR companion grant, at most one hour; limited to the issuer's authority and target. Not a standalone native member. |
| Host | Ceremony-pinned `add_host` identity/key and trust generation, independent of a locked credential key agent or Mac availability. |

Use the signed hash chain, durable head and connection-carried suffix specified
by Atem. Verify account/root, signatures and predecessor authority; commit
membership and apply r8 control fences before judging the sender. An unknown
or removed carrier can deliver an authentic removal without gaining access.
The host never rolls back an accepted head. Apply removals to every affected
attachment, stream, queued request and raw terminal write, including after
restart. No attestation, freshness heartbeat, manager-expiry or routine second
signing key is required by the agreed direction.

Revocation propagation is eventual: a relay can hide an unseen removal until
an honest carrier reaches the host. A durable head cannot bound that delay.
Do not present the removed 24-hour freshness claim as a guarantee. A valid
conflicting history from a still-current manager freezes remote access; local
host use remains available. Removed-key conflicts cannot freeze it. Honest
concurrent signing and exact signature-retry bytes follow the r9 fixtures;
a conflict alone does not prove key theft. Managers and the Recovery Kit
cannot lift a freeze. Compromised manager/freeze recovery is local unpair/pair
with a new pinned genesis/trust generation.

## Authentication and recovery

Routine channel signing can reuse an owner confirmation for **at most five
minutes**, cleared on device lock or app background. Enrollment, removal and
recovery require fresh Face ID/Touch ID confirmation. Platform key policy
must enforce this without exporting a manager key to software. Retain the
OS password/passcode fallback where supported, including a closed-lid Mac;
the app does not collect the OS password. Atem verifies key possession, not
whether a biometric prompt happened.

Create the mandatory offline Recovery Kit at account setup and pin its public
signing key in genesis. The expanded format holds R, account_id, genesis_hash,
kit_tag and relay URL, using the shared R9.5 derivations. Show it only after
genesis commits. Replacements stay bound to that genesis; older kits missing
the anchor must be re-issued through the agreed replacement flow.
Offer export to a password manager or printed phrase/QR
and require confirmation it was saved. A kit must actually recover K: the
existing signing-recovery seed and data-key export are distinct formats.
Astations own the versioned kit, recoverable-K envelope/export, account/root/kid
binding, retained key generations, rotation/backup updates and interrupted
restore handling, using the agreed shared formats. Keep secret material out
of relay records, logs and shared memory.

When every Astation device is lost, restore K on a new native device and use
the kit to sign the restricted add-manager entry on the **existing** chain.
Existing hosts continue without re-pairing. Atem only verifies/applies that
recovery-signed entry; there is no `atem trust recover` command. The kit
cannot reset trust, remove devices, change its genesis pin or unfreeze a host.
Recovery enrollment waits 24 hours from each host's first sight, using both
monotonic and wall time; the subject has no access meanwhile. A manager can
approve it immediately or veto it while pending. Kits are replaceable: a
manager plus the current kit co-signature acts immediately; a manager without
the kit uses the same wait and approve/veto. A replaced kit never signs again.
Restore verifies the kit tag and independent genesis anchor before trusting
any relay-supplied log, host or backup. It waits for a reachable host-signed
head: no host means no K stored as current and no signed/published recovery,
rotation or backup. Explain how to resume. The user rejected the earlier
unconfirmed-restore fallback. After a recorded membership write fault or
unreconcilable carriage the host is held; reconnect a current native manager
for reconciliation. Ordinary crashes replay durable carriage and resume.
Held is distinct from a frozen account, which a manager cannot unfreeze.
Lost devices are removed explicitly in Settings, never automatically. A stolen
device is removed by a signed membership entry; a compromised manager or freeze
requires local host re-pairing.

Atem v0.7.2 keeps `atem_id` in `config.toml` while resetting local storage.
Today's same-ID verification atomically replaces the encryption/signing/
unlock-auth pin, advances its epoch and grants existing K to the new encryption
key. Regression tests cover durable replacement, failed saves, old-key refusal
and stale migration work. Never infer a new-ID replacement from a hostname.

## Concurrent control and operations

| Operation | Behavior |
| --- | --- |
| View terminal/chat/history | Multiple authorized clients read the same original session; opening a view does not launch an agent or take control. |
| Send prompt | Atomically acquire an unowned lease or use this attachment's lease. If another holder exists, show it and require confirmed Take over and send bound to the displayed expected holder/epoch. |
| Terminal write/paste/resize, interrupt or stop | Explicit held control lease; one holder per session. Different sessions can have different holders. Local input wins. |
| Answer approval/revoke rule | Control permission and the exact authoritative request/rule, without acquiring/changing the lease; first valid answer wins. Claude/Codex Always allow uses the exact offered rule. |
| Disconnect/sleep/reconnect | New channel/attachment, authoritative registry/history/approval/receipt catch-up. No restored lease, implicit control or replayed prompt. Other clients remain independent. |

Preserve r8's five-second renewal, 15-second lease expiry, durable accepted
before acknowledgment and durable executing before agent effects. Capture
immutable authenticated principal and connection context before asynchronous
dispatch; never resolve identity later from a live socket or claimed body.
Keep scope/permissions, full targets, control generations and failed-journal
fences at admission and dispatch. A transport ACK is not an agent receipt.
An ephemeral client can disconnect after bounded delivery/receipt recovery.

## Rich message presentation

See [agent status capture and API delivery](agent-status-api.md) for the
Claude/Codex evidence sources, shared activity model and existing versus
planned API paths. Process liveness, activity, connection freshness and
durable request outcomes are separate facts.

Opening an agent response in mobile Astation must preserve its formatting,
not flatten it into plain text. The existing chat model already carries text
as `kind: text` with a `markdown` field, plus distinct tool and approval parts
(`AgentChatPart` in Astation). Basic formatting needs a renderer, not a new
host message type or token-by-token streaming.

| Content | Required mobile presentation |
| --- | --- |
| Paragraphs and headings | Preserve paragraph boundaries and heading hierarchy; wrap prose to the viewport. |
| Emphasis | Bold, italic and strikethrough according to the agreed Markdown profile. |
| Links | Visually distinct clickable links, with destination inspection and explicit user navigation. |
| Lists and quotes | Ordered/unordered lists, task lists and block quotes with readable indentation. |
| Code | Inline code and fenced blocks, language-aware highlighting where supported, a copy action and horizontal scrolling for long lines. |
| Tables | Preserve rows/columns with contained horizontal scrolling on narrow screens. |
| Tool activity and approvals | Separate typed cards; show safe tool summaries and authoritative approval state/actions. |

Keep original Markdown, part boundaries and stable message/part identifiers
in the client read model and API output. Render locally; neither the relay nor
the API converts messages into flattened text or server-generated HTML. Use a
common documented Markdown profile and shared rendering examples across Mac,
mobile and web, with platform-specific view adapters. Text selection/copy,
accessible labels and user font sizing must work without breaking code/table
layout. Layout may adapt to the screen while content/meaning remain intact.

Render Markdown as untrusted content: disable embedded HTML/scripts and
executable links, and do not automatically fetch remote images/resources.
Opening a link is a user action, not a command submission or approval.
Actionable approval buttons come only from the validated typed pending
approval, never from a model-generated Markdown link or imitation card.

Whole-message replacements and history/reconnect use the same renderer and
ordered read model; pagination must not drop formatting or regress a newer
message version. Handle malformed/unsupported Markdown with a readable source
fallback and existing size bounds. Image, audio, PDF and other attachments
need separately agreed typed parts, permissions and transfer support; existing
text/tool/approval parts do not promise those capabilities.

## High-level client API and public transport

The [unified Integrations design](../unified-integrations.md) proposes one Portal
setup flow and one Station API. Existing relay/storage modules remain opaque;
an optional agent module handles Bearer-token API calls and Discord through the
shared R9 client, with a distinct native-authorized service identity per
integration. No extra public service/deployment is required. Agora.Build owns
account/API authentication, integration management and Stoa/RTC/screen sharing.
Station validates Auth-issued credentials and handles transport/storage/runtime;
private data stays on the chosen Station. Enabling an
integration trusts its Station/operator to handle that integration's permitted
plaintext; it does not expose native/direct R9 channels or account K. The
module's Auth binding, retention and new API routes still need review and
implementation; no R9 wire change is assumed. Shared-relay users can keep the
agent module disabled and use native/direct encrypted channels.

Use `atem-client` for listSessions, sendPrompt, readHistory, watchEvents,
answerApproval, revokeRule and queryReceipt. A bot is an authorized decrypting
endpoint with its own scoped key, not the Mac's local bearer token. Posting
output to Discord discloses it to Discord, not to the relay.

Start with WSS; whole-message updates are sufficient. A later Agora Signaling
adapter must preserve the same encrypted channel, ordering, scope, attachment,
lease and receipt semantics. Verify runtime/network support before adopting
that adapter. Transport presence/login/ACK never replaces enrolled device proof.
APNs/FCM remains the offline channel regardless of foreground transport.

The relay `/api/remote/v1` families cover capabilities, enrollment
rendezvous, exact signed membership retrieval/conditional append, verified host
advertisements, and opaque channels/frames/ordered events. Only the public
readiness endpoint, authenticated signed-log/K-backup storage, fresh host probes
and independent encrypted WebSocket channels are implemented on this branch.
Capabilities advertise revision 9/WebSocket and enable routing admission with
durable recovery storage. Identity/permission admission remains authoritative
on Atem. Signed push/seen ingress and native attendance now exist; provider
dispatch remains gated on membership-bound registration and durable stage jobs.
Enrollment, host discovery and [host rejoin](r9-host-routing-lifecycle.md) still
have separate gates; unimplemented paths return 503.
See [the API status](../../docs/remote-api.md). Final methods, limits, errors, cursor/reset behavior and envelopes
follow the jointly pinned contract. A plaintext relay chat API would change the
E2EE boundary and is not this design.

Atem's outbound-link multiplexing contract and built artifact handoff are
reviewed in the [channel envelope review](remote-agent-api-channel-envelope-review.md)
at final Task 7 pin `edeb8f0fab71d4573e41c4ca7935aab207200caf`.
The corrected envelope fixtures, bounded restart lifecycle, 2 MiB router
obligation and strict original-JSON generation reader are agreed for
implementation. Built SwiftPM/xcframework, WASM and Kotlin/JVM Linux packages
verify against that exact pin. The narrow native FFI consumer check passes;
full adapters, runtime and platform tests still gate admission. Consume the
built core with no legacy verification fallback. Android ABI libraries and
Atem's final Task 9 artifact/harness handoff and Astation conformance remain separate gates.

Enrollment binds the applicant's auth/encryption key possession, account/root,
roles/scopes, both nonces and an expiring single-use ceremony. Native owner
authentication signs that exact transcript/current predecessor; a delayed
result cannot authorize changed keys, roles or head. Services have explicit
bounded scopes; browser code integrity and companion control get a separate
review. Remote process launch, file/image/audio/PDF uploads and vault access
need their own capabilities/permissions.

## Approval notification escalation

The approved policy is the [#81 decision](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276488130):

| When | Delivery |
| --- | --- |
| Immediately | In-app card/event for connected eligible clients. If no desktop Astation is connected, send the desktop OS notification immediately. A mobile recipient can opt into immediate push. |
| 60 seconds from original creation | If unanswered, open, unexpired and not actively seen, send mobile push. An optional desktop reminder may also be sent. |
| Active-user seen | A rendered card in a focused foreground window with an active user suppresses mobile escalation. Background delivery, an unopened notification or an unattended open app does not qualify. |
| Answered/closed | Authenticated answer in any app or terminal, cancellation or expiry cancels all remaining jobs and clears delivered notices where supported. |
| Near expiry | Do not send at/after expires_at minus the agreed margin. This suppresses delivery only: a still-valid card is not marked expired or disabled early. |

Seen never answers or closes a card, changes control, or reopens a resolved
request. The client emits the authenticated exact-approval signal using the
agreed r9 schema. Desktop connection state is only a routing hint; notification
preference identifies desktop/mobile delivery without granting any authority.
Filter before provider submission: a suspended mobile app cannot reliably
suppress an already OS-rendered push. The numeric expiry margin and precise
signed delivery/seen shapes must be pinned in r9, not chosen independently.

Atem emits a signed open immediately with immutable original created_at and
expires_at, and emits resolution on closure. Tool/summary are sealed per current
control recipient. The relay stores lifecycle, seen/resolution tombstones and
per-recipient/stage jobs durably across both replicas; no Mac timer or
Mac-forwarded approval is required. Duplicates/reconnect/failover cannot move
deadlines or revive a notice. Revalidate lifecycle, authority, token generation
and expiry before each provider attempt. See the [push integration requirements](approval-push-proof.md).

## Implementation order and readiness

1. Contract implementation is signed off at
   `c685abab92535b167f5f2658c814f0f72541d9a1` on PR #80. The
   [r5 review](remote-agent-api-atem-r5-review.md) closes the previous findings
   after checking the changed contract and 69 fixtures. Primitive/example
   checks pass 274 Python and 41 CryptoKit assertions; 148 symbolic references
   resolve. At that sign-off the 62 scenarios were NOT RUN. Later upstream
   host/core runners are reviewed separately; actual Astation relay/platform
   conformance still gates admission.
2. Atem builds/verifies the shared `atem-client`, binding artifacts and host
   implementation. Agree durable state/effect ordering and FFI lifecycle;
   r9 only, retaining r8 operation semantics.
   The [final Task 7 review](remote-agent-api-channel-envelope-review.md)
   accepts pin edeb8f0 and its matching verified packages, closing the earlier
   final-pin wait. The requested three-key retry/lock regression is present;
   upstream CI and 19 local Swift/static-library checks pass. Consume these
   packages for the complete ceremony/adapters; do not build Atem source or
   partially patch legacy verification. Android ABI/Task 8/Task 9 handoffs
   and full Astation integration/conformance remain.

3. Astation integrates platform keys/owner authentication, mandatory kit and
   restore, Add device/service and Settings removal, shared-core bindings,
   native adapters and relay signed-record/encrypted transport storage.
4. Build authenticated sealed push/seen ingress, durable scheduler, platform
   notification registration/decryption and foreground-active-user detection.
5. Run the independent Mac/mobile-equivalent/bot harness, Mac-off matrix,
   real provider/biometric checks and rich-message rendering tests. Browser
   companion control remains separately reviewed.

The user has authorized building once both sides are ready. Start settled
platform/relay work where independent of unfinished formats, but emit no new
wire operations or enable remote admission until the contract and fixtures
are jointly pinned. No compatibility fallback or verification bypass. Main
merges deploy production and still require the user's merge authorization.

Current implementation: public readiness/gating, v2 ceremony/recovery storage
and an isolated approval delivery policy are built and tested. Authenticated
independent session ingress, public agent operations and provider dispatch
remain disabled. The policy derives deadlines
from original creation and accepts a delivery margin. It awaits
the authenticated lifecycle/shared-core integration before outbox delivery.
Recovery enrollment delay, kit replacement, wait-for-host restore and the
fault-held policy are settled as above. There is no pending product choice
from this review.

## Tests without phone applications

Use independent native/mobile-equivalent controllers with real separate keys,
a scoped bot, a host with disposable Claude/Codex sessions, two relay replicas,
Postgres and Valkey. Mobile UI is unnecessary for protocol/API verification.

| Area | Required cases |
| --- | --- |
| Trust/channel | Wrong account/root/host/key/generation; replay/tamper; divergent heads; suffix before sender admission; rollback; honest forks; removed/current-key conflict; invalid tail, fsync/crash and replayed fences. |
| Enrollment/recovery | Applicant substitution, duplicate/expired ceremony, changed head during owner auth; mandatory saved kit; K/key-generation restore; lost-all-manager replacement without re-pairing; frozen host refuses kit unfreeze. |
| Concurrent control | Mac/mobile view same process; mobile approval/rule revoke leaves Mac lease/deadline unchanged; atomic Send, stale expected-holder takeover, local input, late renewals and independent reconnects. |
| Receipts/history | Immediate disconnect after acceptance, bounded query recovery, no replay; sequenced whole-message history/pages/end/coverage, persistent holes/truncation and cursor reset. |
| Push | Desktop-connected routing vs no-desktop immediate delivery; mobile at 60 s; mobile immediate preference; active seen vs unattended/background; resolution-before-open; seen-after-answer; expiry margin; duplicate/late/restarted workers; token rotation and revoked recipient. |
| Rich content | Markdown/typed parts byte-for-byte through live/history/reconnect; mobile paragraph, link, emphasis, code and table rendering; inert HTML/links/resources; accessibility and readable source fallback. |
| Independence | Mac on/off/wake does not gate phone/bot or take another client's lease; host key works independently of credential key-agent lock. |

Use fake providers and a controllable clock for deterministic scheduling and
sealed payload inspection. Separately test provisioned platform key access,
biometrics/passcode behavior, real APNs/FCM background delivery and actual
mobile rendering. A provider fake or headless harness cannot prove those.
