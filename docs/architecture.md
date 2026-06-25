# Plink Architecture

## Summary

Plink is a local-first companion system:

- Android app: Pixel-side permission manager, event collector, and continuity sender.
- macOS app: menu bar companion, pairing host, native notification presenter, and reply/action router.
- Shared protocol: versioned JSON envelopes over a local authenticated TCP channel.

Plink does not attempt to use private Apple Continuity APIs. It implements the closest public-API equivalent.

## Components

### Android

- Jetpack Compose app shell with Material 3 UI.
- `PairingStateMachine` for device linking and emoji confirmation.
- `PlinkMessage` protocol models.
- `ConnectionRepository` for local peer state.
- `PermissionModel` for notification, phone state, SMS/default-role, accessibility, local network, and Shizuku capability visibility.
- `NotificationBridgeService` abstraction for message/call notification mirroring.
- `ContinuityEventRepository` for calls, messages, clipboard, files, web links, battery, and media commands.
- Android Keystore-backed storage planned for production secrets; local test implementation uses injectable storage.

### macOS

- SwiftUI app with AppKit `NSStatusItem` menu bar integration.
- Pairing window with matching emoji confirmation.
- `PlinkMessage` protocol models matching Android.
- `PairingStore` for remembered device state.
- `NotificationBridge` using `UNUserNotificationCenter`.
- Native call notifications with answer/decline actions.
- Native message notifications with text reply action.
- Pasteboard/file/URL handoff adapters.
- `Network.framework` transport boundary for local peer connections.

## Pairing Flow

1. One device creates a pairing offer:
   - device id
   - device name
   - platform
   - local endpoint
   - nonce
   - protocol version
2. Both devices derive a short visual confirmation from the offer hash.
3. UI shows a matching emoji pair, for example `sparkles + key`.
4. User confirms only when both screens match.
5. Plink stores a paired-device record and a shared session id.
6. Future events must include the paired device id and protocol version.

MVP pairing uses deterministic emoji confirmation and local session modeling. Production encryption should add Noise/HPKE or TLS with pinned per-device certificates before sensitive real traffic.

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
- Phone state: required for direct call-state visibility.
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

- User-confirmed emoji verification.
- Paired-device allowlist.
- Protocol versioning and event validation.
- Permission-gated feature toggles.
- Redaction defaults for sensitive notification content.
- No Shizuku dependency for baseline behavior.
- Future production encryption before real sensitive payload sync.

## Release Gates

- Android unit tests pass.
- macOS Swift tests pass.
- Protocol fixtures match on both platforms.
- `scripts/verify.sh` passes.
- Feature parity document lists public-API parity and private-API gaps.
- GitHub repo is public and pushed from `main`.
