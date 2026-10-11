# Atem Storage-Key Unlock UI

An accepted unlock request opens one modeless window with the device name,
boot ID, request time and last successful unlock. Apple's
`LAAuthenticationView` embeds the system Touch ID control in this window.
Authentication starts after the window is visible, without an extra Approve
click or a separate system authentication alert. The surrounding text states
that a Touch ID match approves release of this device's sealed keys.

The window keeps **Deny** and **Deny and Revoke**. Deny closes the request
without changing verification. Deny and Revoke removes the local E2E pin
through the existing storage-key controller and requires fresh verification.
Closing the window, cancelling or failing authentication denies the request.
When Touch ID is unavailable, the same window explains how to enable it; no
alternative authentication method or approval action is offered.

## Lifecycle and Security

- The embedded view and policy evaluation use the same fresh `LAContext`.
  Only `deviceOwnerAuthenticationWithBiometrics` is evaluated. Password
  fallback and reuse of a recent Mac unlock are disabled.
- The controller validates the signed request and current local device pin
  before presentation. Displayed device names and boot IDs have control and
  Unicode formatting characters removed and their lengths bounded. They
  describe the request; they do not authorize it. No key material is displayed.
- Only one verification, recovery or unlock prompt can be active. Biometric
  replies are delivered to the main queue. Completion clears the callback,
  invalidates authentication and closes the window exactly once.
- Cancelling before authentication starts prevents policy evaluation.
  Disconnect, timeout, account change and replaced connection cancellation
  invalidate the context; late or duplicate biometric replies have no effect.
- The existing controller rechecks the captured connection, account, expiry
  and local pin before releasing a key. A successful Touch ID result cannot
  bypass those checks. Revocation remains an explicit button action.

## Validation

Tests inject an authentication context so they cannot prompt for real Touch ID.
They cover embedded view/context binding, automatic biometric evaluation,
visible metadata and controls, sanitization, unavailable Touch ID, approval,
denial, explicit revocation, window close, cancellation before evaluation,
duplicate and delayed replies, and the shared prompt gate. Existing controller
tests continue covering disconnect, expiry, account and revocation races.
The real Touch ID sensor and rendered system control need local verification.
