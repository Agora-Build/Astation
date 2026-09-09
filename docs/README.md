# Architecture and Feature Guides

These documents describe current behavior, architectural decisions, and remaining
work. Completed implementation checklists are available in Git history.

| Document | Why it is retained |
| --- | --- |
| [Android device sharing](android-device-sharing.md) | Connection model, setup, lifecycle, and pending phone/IDE validation |
| [SSO authentication design](sso-authentication.md) | Browser login, token refresh, encrypted session storage, and credential consumers |
| [Vault storage design](vault-storage.md) | Storage semantics, persistence, caller resolution, and concurrency boundaries |
| [Device Authentication v2](specs/2026-07-21-device-authentication-v2.md) | Wire protocol shared with Atem and unresolved production blockers |

For local builds and user setup, start with the [project README](../README.md).
For relay deployment and API configuration, use the
[relay README](../relay-server/README.md).
