# Changelog

## 0.1.0

Initial public foundation for Plink.

- Added native Android companion with Kotlin, Jetpack Compose, Material 3 UI, permission state, notification mapping, and reply-route models.
- Added native macOS companion with SwiftUI/AppKit menu bar app, UserNotifications call/message presentation, text reply routing, pasteboard/URL handoff adapters, and Keychain-backed session secret storage.
- Added shared Plink protocol fixtures and schema for pairing, calls, messages, clipboard, and web handoff.
- Added P-256 ECDH pairing primitives with key-bound four-emoji and six-digit verification codes.
- Added AES-GCM encrypted local transport with HMAC frame signatures, replay checks, expected device-id checks, and length-prefixed TCP framing.
- Added Android Keystore-backed paired-device and session-secret storage, saved-session bootstrap, outbound bridge configuration, and inbound reply receiver plumbing.
- Added Android `RemoteInput` reply validation/execution path for source apps that expose safe notification replies.
- Added macOS secure receiver startup after pairing/session restore and strict packaging/export script.
- Added automated verification through `scripts/verify.sh`.

Known release limits:

- Production pairing UI and cross-device offer/confirm exchange still need real-device validation.
- Android release signing, macOS Developer ID signing, notarization, and store distribution require account secrets outside this repo.
- Real Pixel-to-Mac E2E evidence is still required before public end-user release.
