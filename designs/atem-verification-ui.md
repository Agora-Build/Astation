# Atem Safety-Code Verification UI

Pairing shows one modeless window containing the requesting device, a prominent
selectable safety code, comparison instructions and Apple's embedded
`LAAuthenticationView`. The user compares the code with `atem pair` and clicks
**Codes Match**. That action starts Touch ID inside the same window, keeping
the code visible throughout authentication. It does not complete verification
by itself. **Deny** remains available before and during authentication.

Both biometric prompts share a 420-point content column, rounded detail cards
and a consistently aligned Touch ID panel. Device details use labeled rows;
the safety code has a distinct, softly accented card. Secondary guidance stays
below the cards. Native semantic colors adapt to light and dark appearances,
and long device labels wrap within the card instead of widening the window.
The authentication panel reserves space for unavailable-Touch-ID guidance so
the layout remains stable during evaluation.

Unlike the [storage-key unlock prompt](atem-unlock-ui.md), verification must
not start Touch ID automatically. An incidental biometric match before code
comparison must never approve a device.

## Lifecycle and Security

- The verification controller validates the commitment and derives the code
  before presentation. The UI never takes a safety code or device identity
  from a relay approval. Displayed device labels are sanitized and bounded.
- The embedded view and evaluation share a fresh `LAContext`. Clicking Codes
  Match enables one biometric evaluation after the window is visible. Further
  clicks cannot start another evaluation or complete approval.
- Only `deviceOwnerAuthenticationWithBiometrics` is evaluated, with password
  fallback and reuse of a recent Mac unlock disabled. Unavailable Touch ID
  displays guidance in the same window without hiding the code or offering
  another approval method.
- Approval requires both explicit code-match confirmation and successful
  biometrics. Denial, window close, peer abort, disconnect or timeout invalidates
  the context. Completion runs on main exactly once; queued, duplicate and late
  biometric replies cannot change a completed or replacement request.
- The shared verification/recovery/unlock prompt gate remains in effect. The
  existing controller rechecks account, connection generation, expiry and
  signing identity before committing a device pin or sending a grant.
- First-device recovery-kit confirmation remains a separate required step.
  Combining the comparison and biometric UI does not replace that approval.

## Validation

Injected-context tests cover no authentication before code confirmation,
one evaluation after confirmation, code/control visibility during evaluation,
fresh biometrics, unavailable Touch ID, denial before and during evaluation,
window close, queued/late/duplicate replies, background callbacks and shared
prompt gating. Existing protocol/controller tests cover commit binding,
disconnects, replacement accounts/connections, expiry and durable verification.
Physical Touch ID and the comparison against a live remote Atem need manual
verification.
