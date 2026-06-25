# Manual Test Plan

## Release Gate

1. Run `./scripts/verify.sh`.
2. Confirm Android debug and release builds finish.
3. Confirm macOS bundle is created at `build/PlinkMac.app`.
4. Confirm the Android manifest gate rejects raw SMS permissions.
5. Confirm `codesign --verify --deep --strict build/PlinkMac.app` passes.
6. For public distribution, set `MACOS_CODESIGN_IDENTITY` to a Developer ID identity and notarize the bundle.

## Android

1. Install debug build on Pixel.
   `adb install -r android/build/outputs/apk/debug/android-debug.apk`
2. Open Plink.
3. Confirm Google-style Material UI loads.
4. Enable notification listener.
5. Enable notifications.
6. Optional: enable phone state, SMS/default SMS role, accessibility clipboard, and Shizuku.
7. Confirm pairing screen shows emoji code `⚡ 🔑` for demo pairing.
8. Trigger simulator events and confirm generated event types match shared fixtures.
9. Confirm SMS is shown as a future/default-role mode, not as a requested install permission.
10. Confirm notification listener creates reply routes for replyable notifications and consumes reply tokens once.

## macOS

1. Run `swift run PlinkMac` from `macos/`.
2. Confirm Plink appears in the menu bar.
3. Open pairing window.
4. Confirm emoji code matches Android.
5. Click `Simulate Call`; confirm native macOS notification appears.
6. Click `Simulate Message`; confirm native macOS notification appears with reply action.
7. Send a reply and confirm it is converted into a `message.reply` event targeting the paired Pixel.
8. Disable notifications in System Settings and confirm the menu reports the denied/error state.
9. Confirm `build/PlinkMac.app` is signed with the expected identity or ad-hoc identity for local testing.

## Cross-Device

1. Put Pixel and Mac on the same local network.
2. Start macOS app.
3. Start Android app.
4. Pair only if emoji code matches on both devices.
5. Send sample `call.ringing`, `message.received`, `clipboard.updated`, and `web.open` events.
6. Confirm unsupported permissions degrade visibly instead of failing silently.

## Negative Cases

1. Pair only when both emoji codes match.
2. Tamper with a signed envelope and confirm it is rejected.
3. Send a `javascript:` web handoff and confirm it is rejected.
4. Send a reply with blank text and confirm it is rejected.
5. Send a message reply without the original notification route and confirm it is rejected.
6. Trigger large payloads above 64 KB and confirm they are rejected.

## Evidence Matrix

| Area | Evidence |
| --- | --- |
| Pairing | matching emoji code, paired device stored |
| Calls | macOS native notification appears |
| Messages | reply action creates `message.reply` |
| Clipboard | clipboard event writes through adapter |
| Web | `http`/`https` only |
| Security | signed envelope tamper test fails closed |
| Release | Android APK build and `PlinkMac.app` bundle exist |
