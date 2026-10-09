# Architecture and Feature Guides

These documents describe current behavior, architectural decisions, and remaining
work. Completed implementation checklists are available in Git history.

| Document | Why it is retained |
| --- | --- |
| [Agent handoff](agent-handoff.md) | Audited remaining identity work, validation gaps, and conditional operations follow-ups |
| [Relay identity](astation-relay-identity-handoff.md) | Signing-key contract, durable pairing protocol, reconnect behavior, and recovery runbooks |
| [Android device sharing](android-device-sharing.md) | Connection model, setup, lifecycle, and pending phone/IDE validation |
| [Local audio recording](audio-recording.md) | Capture sources, original tracks, permissions, and practical Mac validation |
| [Live transcription](live-transcription.md) | Local/cloud captions, draggable floating window, model downloads, privacy, and validation |
| [Screen sharing](screen-sharing.md) | ScreenCaptureKit capture, Agora publication, optional system audio, browser controls, and verification |
| [SSO authentication design](sso-authentication.md) | Browser login, token refresh, encrypted session storage, and credential consumers |
| [Vault storage design](vault-storage.md) | Storage semantics, persistence, caller resolution, and concurrency boundaries |
| [Device Authentication v2](specs/2026-07-21-device-authentication-v2.md) | Wire protocol shared with Atem and unresolved production blockers |
| [Relay device key recovery](relay-device-key-recovery.md) | Keychain access retries, authenticated signing-key repair, and the relay trust reset workflow |

For local builds and user setup, start with the [project README](../README.md).
For relay deployment and API configuration, use the
[relay README](../relay-server/README.md).
