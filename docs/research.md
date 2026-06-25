# Plink Research

## Goal

Plink brings Pixel-to-macOS continuity as far as public Android and macOS APIs allow:

- Pair Pixel and Mac on a local network with a matching emoji confirmation code.
- Mirror calls and messages to macOS as native actionable notifications.
- Reply to supported messages from the macOS notification.
- Share clipboard, files, web links, media state, and device/battery state.
- Keep privileged or sensitive access explicit, permissioned, and optional.

## Reference: Sefirah Android

Reference repo: https://github.com/shrimqy/Sefirah-Android

Useful feature cues from Sefirah:

- Local phone-link model for Android plus desktop.
- Clipboard sharing between phone and desktop.
- Desktop notification mirroring from Android notifications.
- File sharing.
- SMS texting when SMS permissions are granted.
- Media controls and remote volume commands.
- Battery and device status.
- Screen mirroring through external scrcpy integration.
- Pairing flow with user confirmation and matching keys.
- Android permission screen for notification listener, accessibility, SMS, phone state, and related capabilities.

Useful Android implementation cues:

- `NotificationListenerService` for notification mirroring.
- Accessibility service for clipboard detection where normal clipboard callbacks are insufficient.
- Device-specific preference toggles for clipboard, messages, notifications, media, storage, call state, and call logs.
- Persistent connected-device foreground service.
- Explicit SMS permissions when implementing direct SMS.

## Platform Feasibility

| Feature | Feasible Level | Implementation Path | Boundary |
| --- | --- | --- | --- |
| Pairing | High | Local network discovery/manual connect, emoji confirmation, per-device secret | Bonjour/Nearby can be added later; MVP supports manual local pairing and socket discovery model |
| Calls on Mac | Medium-high | Android call state/notification listener sends call event, macOS shows actionable native notification | Direct cellular call audio handoff like iPhone is not public Android-to-macOS API |
| Message reply from Mac notification | Medium-high | Android notification listener captures `RemoteInput` reply actions, Mac reply action sends response event back | Direct SMS send requires SMS default role or privileged SMS permissions; notification replies work only for apps exposing reply actions |
| SMS texting | Medium | Optional SMS permission/default-role path | Play policy and user default SMS role constraints apply |
| Clipboard handoff | High | Android accessibility/manual share plus macOS pasteboard monitor | Background clipboard access is restricted on modern Android; user enablement required |
| File handoff | High | Android share sheet/doc picker and macOS file importer/exporter over local transport | Background filesystem mounting needs a separate storage service and stronger review |
| Web handoff | High | Share URL/open URL event | Safari/iCloud tab parity is private Apple ecosystem behavior |
| Battery/device state | High | Android battery broadcasts and app/device state events | Some hardware details may be unavailable without extra permissions |
| Media controls | Medium-high | Android media session events and desktop control events | App-specific media sessions may restrict control |
| Screen mirroring | Medium | Optional scrcpy/ADB path | Not native Continuity; requires external tooling and user setup |

## Android Constraints

- Notification mirroring needs user-enabled notification listener access.
- Android 15 and later can hide sensitive notification content unless the app receives special permission through ADB/app-ops or equivalent user action.
- Message replies via notification require the source app to expose a `RemoteInput` action.
- Direct SMS read/send needs SMS permissions and may require being the default SMS app for policy-compliant distribution.
- Call state visibility may need `READ_PHONE_STATE`; detailed call log behavior needs additional permissions and policy review.
- Clipboard auto-sync is constrained by modern Android privacy limits; foreground, accessibility, or share-sheet paths are safer.
- Shizuku can improve privileged access in developer/power-user mode, but release behavior must not depend on it.

## macOS Constraints

- Native notifications support actions and text reply through `UserNotifications`.
- Menu bar apps need AppKit bridging for `NSStatusItem`.
- Local network messaging should use `Network.framework`.
- Notification reply actions are local app actions; Plink must forward the reply to Android and Android must execute the supported reply path.
- App Store distribution will need sandbox entitlements, local network privacy strings, notification permission UX, signing, and notarization.
- iPhone Continuity features using private Apple services, iCloud identity, Call Relay, and Messages relay cannot be cloned exactly with public APIs.

## Product Boundary

Release-ready means:

- Native Android app and native macOS app compile and pass local tests.
- Pairing, protocol, call/message notification models, reply event flow, clipboard/file/web/device/media event models are implemented and testable.
- Permission-dependent features degrade clearly when unavailable.
- Exact private iPhone Continuity parity is documented as unavailable, with the public-API equivalent implemented where possible.
