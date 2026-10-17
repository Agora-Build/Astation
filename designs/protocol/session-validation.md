# Session joint validation

Updated 2026-10-17. Astation PR #50 pins Atem PR #72 at
`6edda2490f4a4b7634edb446f64aa02748e29fa2` (r7.1), including the complete
fixture directory and checksums in Tests/AstationTests/Fixtures/atem-session-v1/source.json.
No Atem checkout was modified or built. The installed Atem on this Mac is
0.6.9; the current remote Genie runtime belongs to the Atem owner.

## Coverage and live results

Automated coverage uses Astation's real decoder, session client, terminal
coordinator, journal and local HTTP API with deterministic host responses.
It establishes client behavior; it cannot establish host admission, PTY
effects, provider completion or live approval delivery by itself.

| Check | Astation automation | Joint live result |
| --- | --- | --- |
| hello, welcome, list, sessions | Authenticated-context and full-target checks; registry sequence reset | Passed on Genie with Claude and Codex; exactly one online Atem |
| r7.1 replacement hello | Shared request shapes decode with UUID ${gen2}; a recreated client on the same authenticated transport clears authority, queries the original receipt, refuses old grants and explicitly reacquires at the new epoch | Host scenario not run by Astation; Atem must run second-hello-replaces-the-attachment.json against its host runner |
| Retry and sleep/wake | Retry reconnects the socket; sleep fences authority and closes transports; changed local socket generation fences stale callbacks | Provisioned app reconnects after relaunch; physical sleep/wake UI run remains pending |
| Error text | Post-welcome unauthorized reconnects; initial refusals stop without a retry loop or misleading verification instruction | Authenticated Genie handshake succeeds |
| Process indicator | Running/unknown-activity is running; all four activity labels and stopped states covered independently | Confirmed in the user's screenshot: Codex green / Unknown, Claude green / Idle, one online Genie |
| Terminal view/control/type/resize/paste/release | Bound stream, target, lease and write-queue tests | API acquire/release passed; full terminal UI exercise pending |
| Session selection | Selecting a different agent automatically subscribes in viewing mode, releases previous control, fences late attachments/frames and waits for any pending registry refresh | Provisioned local app rebuilt; physical selector retest pending |
| Desktop clipboard and Paste & Go | Actual WebKit Cmd+V default cancellation, native Edit/context-menu paste, one-write bracketed paste plus Enter, and empty/oversized/stale/read-only rejection | User reported double Cmd+V in Claude on the prior build; physical retest on this provisioned build remains pending |
| Local input wins | Lease-change and queued-write fencing tests | Physical local-input versus remote-input race pending |
| Lease expiry and late renewal | Exact monotonic deadline and delayed-grant tests | Client renewals paused 17 seconds: host controller cleared, client control expired and remained released; a specifically delayed renewal reply still needs host timing control |
| Claude prompt and receipts | Durable-before-send, receipt transitions, UUID retry and payload-conflict tests | Print-only prompt completed; identical UUID returned the original request, changed bytes refused, control released |
| Interrupt and stop | Bound mutation, receipt and stale-target tests | Pending in a dedicated disposable test session |
| Disconnect immediately after accepted | Reconnect queries original receipts, never replays submissions or restores leases | Quit/relaunch during executing recovered the original completed receipt without control; the exact accepted-before-executing race still needs host timing control |
| Unpair, pair, verify | Authenticated-context loss and old-trust fencing tests | Pending coordinated pairing with the user's local approval; existing pairings retained |
| Real approval decisions | Rule selection, atomic answers, closed/duplicate catch-up, local takeover, expiry, disconnect and uncertain-outcome tests | No live approval card emitted yet; Atem must stage permission-triggering Claude/Codex prompts |

Validation: all ten WebKit renderer tests pass. The full Swift suite executes 907 tests,
with 11 environment-dependent skips and zero failures. The personal-team
provisioned build passes strict signature, protected Keychain identity and
terminal-resource checks and is running with the local API reporting r7.1.

The toolbar now offers Paste & Go instead of separate Copy and Paste buttons.
Ordinary clipboard actions follow focus and do not append Enter. Paste & Go
explicitly targets the selected controlled terminal and includes the final
Enter outside bracketed-paste markers in the same guarded write.

The disconnect test used harmless delayed prompt request
afabc6fe-2496-4141-9702-581de0281a7d. The first observed host receipt was
executing; after relaunch it became completed. Both sessions stayed running
with controls:false. The lease test acquired without takeover, sent no agent
input, paused only the Mac client for 17.17 seconds, then observed
controller:null and "Control expired. Take Control explicitly to type again."

## Shared fixture boundary

The fixture schema labels second-hello-replaces-the-attachment as host-side.
Its six client requests are decoded and round-tripped through Astation's real
wire types; unresolved placeholders are refused, and ${gen2} is substituted
with a valid UUID. A separate real-client lifecycle test covers the same-link
replacement welcome, durable accepted/executing/completed recovery, old
renewal replies, a new explicit epoch-3 acquisition and expiration at the
original authorization deadline.

This does not claim to run the host scenario end to end. In particular, the
host's stale_target response for a deliberately old binding, one-second busy
limit, lease-holder assertions and single-dispatch counter need Atem's runner.
The normal Astation client never deliberately emits the fixture's stale renew.
The three side:client shared scenarios are executed step by step against the
real Astation client. Host fixtures are retained for provenance and joint
testing, including the approval scenarios added with r7.

## Live test setup

Use the [protected local API](../../docs/local-control-api.md) for session
control, prompt/interrupt/stop, approvals and receipt queries without a mobile
client. Terminal rendering/input still use Open Terminal; no terminal-input
HTTP endpoint or skip-verification endpoint is exposed. Use takeover:false
when acquiring a shared test session; release control after each test.

Use a dedicated disposable session for stop/interrupt, lease and immediate
disconnect tests. Coordinate local input and pair/verify with the Atem owner
and the user's biometric/password approval. Do not terminate existing working
agents or discard saved credentials to simulate these tests.
