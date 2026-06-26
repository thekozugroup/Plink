# Plink Architecture

## Summary

Plink is a local-first companion system:

- Android app: Pixel-side permission manager, event collector, and continuity sender.
- macOS app: menu bar companion, pairing host, native notification presenter, secure receiver, and reply/action router.
- Shared protocol: versioned JSON envelopes over a local authenticated TCP channel.

Plink does not attempt to use private Apple Continuity APIs. It implements the closest public-API equivalent.

## Components

### Android

- Jetpack Compose app shell with Material 3 UI.
- `PairingStateMachine` for device linking, ECDH public-key exchange, and key-bound emoji/numeric confirmation.
- `PlinkMessage` protocol models.
- `PermissionModel` for notification, SMS/default-role, accessibility, local network, and Shizuku capability visibility.
- `PlinkNotificationListenerService` for message/call notification mirroring.
- `RemoteInputReplyExecutor` for Android notification-action replies.
- `ContinuityEventRepository` for calls, messages, clipboard, files, web links, battery, and media commands.
- Android Keystore-backed paired-device storage for production metadata and secrets; local tests use injectable memory storage.
- Secure socket client/server with encrypted length-prefixed frames.

### macOS

- SwiftUI app with AppKit `NSStatusItem` menu bar integration.
- Pairing window with matching emoji confirmation.
- `PlinkMessage` protocol models matching Android.
- `PairingStore` for remembered device metadata.
- Keychain-backed session secret storage.
- `NotificationBridge` using `UNUserNotificationCenter`.
- Native call notifications with answer/decline actions.
- Native message notifications with text reply action.
- Pasteboard/file/URL handoff adapters.
- Secure `Network.framework` sender and receiver using length-prefixed encrypted frames.

## Pairing Flow

1. One device creates a pairing offer:
   - device id
   - device name
   - platform
   - local endpoint
   - nonce
   - protocol version
2. Both devices derive a visual confirmation from a transcript that includes device ids, endpoint, nonce, protocol version, and both public keys.
3. UI shows a four-emoji confirmation plus a six-digit numeric code.
4. User confirms only when both screens match.
5. Devices exchange P-256 ECDH public keys inside the pairing offer/confirm flow.
6. Plink derives a session key with HKDF-SHA256 using the pairing nonce and transcript.
7. Plink stores device metadata separately from session secret material.
8. Future events must include the paired device id and protocol version.

Pairing uses deterministic key-bound confirmation plus ECDH-derived session keys. Session traffic is sent as encrypted, signed, length-prefixed frames with replay checks and expected peer/local device-id checks. A future hardening path can replace the direct ECDH/HKDF exchange with Noise/HPKE or TLS with pinned per-device certificates.

## Protocol Envelope

```json
{
  "version": 1,
  "id": "evt_01",
  "type": "message.received",
  "sentAt": "2026-06-25T00:00:00Z",
  "sourceDeviceId": "pixel-1",
  "targetDeviceId": "mac-1",
  "requiresAck": true,
  "payload": {}
}
```

## Secure Envelope

Runtime events are validated before send and after receive:

- protocol version must match
- source and target device ids must be present
- payloads are capped at 64 KB
- web handoff only accepts `http` and `https`
- unknown event types are rejected
- sensitive fields are redacted for logs
- HMAC signatures bind sequence, nonce, timestamp, and canonical event JSON
- encrypted frames bind sequence, nonce, timestamp, source device, target device, and ciphertext
- receivers can enforce expected source and target device ids
- replay checks reject old sequence numbers, reused nonces, and stale timestamps
- network frames use a 4-byte length prefix and reject oversized payloads

## Event Types

- `pairing.offer`
- `pairing.confirm`
- `device.status`
- `call.ringing`
- `call.ended`
- `message.received`
- `message.reply`
- `clipboard.updated`
- `file.offer`
- `web.open`
- `media.state`
- `media.command`
- `permission.state`
- `ack`
- `error`

## Permission Boundaries

Android:

- Notification listener: required for most mirrored app messages and call notifications.
- `RemoteInput`: required for notification-based message replies.
- SMS default app/SMS permissions: required for direct SMS texting.
- SMS permissions are not declared in the Android manifest until the default-SMS-role flow exists.
- Phone state: not requested in the current build; call mirroring uses notification access.
- Accessibility: optional clipboard automation.
- Shizuku: optional privileged helper path; app must work without it.

macOS:

- Notifications: required for call/message presentation and reply actions.
- Local network: required for peer connection.
- Pasteboard/files: used only when the user enables related features.

## Feature Strategy

| Feature | Build Now | Notes |
| --- | --- | --- |
| Pairing | Yes | Emoji confirmation, paired state, protocol events |
| Calls | Yes | Native macOS notification model; no cellular audio relay |
| Message replies | Yes | macOS text reply event; Android executes notification reply when available |
| Clipboard | Yes | Event and local adapter; Android auto mode permission-gated |
| Files | Yes | Offer/accept event model and local file adapter |
| Web handoff | Yes | URL open event |
| Battery/device | Yes | State event and UI |
| Media controls | Yes | Event model and UI controls |
| Screen mirroring | Documented | Future scrcpy integration |

## Threat Model

Primary risks:

- Local network impersonation.
- Sensitive notification leakage.
- Unauthorized message replies.
- Overbroad Android permissions.
- Storing pairing secrets insecurely.

Controls:

- User-confirmed key-bound emoji/numeric verification.
- Paired-device allowlist.
- ECDH/HKDF session key derivation during pairing.
- Encrypted event frames with sequence, nonce, timestamp, and payload policy validation.
- Expected peer/local device-id enforcement on secure receive.
- Protocol versioning and event validation.
- Permission-gated feature toggles.
- Redaction defaults for sensitive notification content.
- Reply events bind to the original notification id, package, notification key, conversation id, paired device id, and reply token.
- Android reply tokens are consumed once from a live route registry.
- Android notification `RemoteInput` actions are kept in memory and expire with reply routes.
- No Shizuku dependency for baseline behavior.
- Android Keystore and macOS Keychain boundaries for session secrets.

## Release Gates

- Android unit tests pass.
- Android debug and release builds assemble.
- macOS Swift tests pass.
- macOS app bundle is generated with menu-bar metadata and sandbox/network entitlements.
- macOS bundle is codesigned locally with entitlements; public distribution requires Developer ID signing and notarization.
- Protocol fixtures match on both platforms.
- `scripts/verify.sh` passes.
- Feature parity document lists public-API parity and private-API gaps.
- GitHub repo is public and pushed from `main`.
