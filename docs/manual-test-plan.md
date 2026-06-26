# Manual Test Plan

## Release Gate

1. Run `./scripts/verify.sh`.
2. Confirm Android debug and release builds finish.
3. Confirm macOS bundle is created at the path printed by `scripts/package-macos.sh` and exported as `build/PlinkMac.app.zip`.
4. Confirm the Android manifest gate rejects raw SMS permissions.
5. Confirm strict `codesign --verify --deep --strict` passes for the printed app path.
6. For public distribution, set `MACOS_CODESIGN_IDENTITY` to a Developer ID identity and notarize the bundle.

## Android

1. Install debug build on Pixel.
   `adb install -r android/build/outputs/apk/debug/android-debug.apk`
2. Open Plink.
3. Confirm Google-style Material UI loads.
4. Paste the Mac pairing offer into `Manual pairing`.
5. Tap `Import` and confirm the four emoji plus six-digit code match the Mac preview after the Mac imports the Pixel response.
6. Tap `Confirm`; confirm the Pixel response is copied and the encrypted session is stored.
7. Enable notification listener only when explicitly testing notification handoff.
8. Enable notifications only when explicitly testing notification handoff.
9. Optional: enable accessibility clipboard and Shizuku.
10. Trigger simulator events and confirm generated event types match shared fixtures.
11. After pairing, use `Preview events` diagnostic buttons for `Call`, `Message`, and `Clipboard`; confirm paired events reach the Mac without changing Android Settings.
12. Confirm SMS is shown as a future/default-role mode, not as a requested install permission.
13. Confirm notification listener creates reply routes for replyable notifications, stores live `RemoteInput` actions in memory, and consumes reply tokens once.

## macOS

1. Run `swift run PlinkMac` from `macos/`.
2. Confirm Plink appears in the menu bar.
3. Open pairing window.
4. Click `Copy Offer` and paste it into the Pixel app.
5. Paste the Pixel pairing response into the Mac window.
6. Click `Preview Response Code`; confirm the four-emoji and six-digit code matches Android.
7. Click `Finish Pairing`; confirm the receiver reports listening after pairing or saved-pairing restore.
8. Click `Simulate Call`; confirm native macOS notification appears.
9. Click `Simulate Message`; confirm native macOS notification appears with reply action.
10. Send a reply and confirm it is converted into a `message.reply` event targeting the paired Pixel.
11. Disable notifications in System Settings and confirm the menu reports the denied/error state.
12. Confirm the printed app path is signed with the expected identity or ad-hoc identity for local testing and `build/PlinkMac.app.zip` exists.

## Cross-Device

1. Put Pixel and Mac on the same local network.
2. Start macOS app.
3. Start Android app.
4. Copy the Mac offer to Android, import it, confirm on Android, then paste the Pixel response back into macOS.
5. Pair only if emoji code matches on both devices.
6. Send Android `Preview events` diagnostics for `call.ringing`, `message.received`, and `clipboard.updated`.
7. Confirm unsupported permissions degrade visibly instead of failing silently.
8. Send an encrypted frame with the wrong source or target device id and confirm it is rejected.

## Negative Cases

1. Pair only when both emoji codes match.
2. Tamper with a signed envelope and confirm it is rejected.
3. Send a `javascript:` web handoff and confirm it is rejected.
4. Send a reply with blank text and confirm it is rejected.
5. Send a message reply without the original notification route and confirm it is rejected.
6. Trigger large payloads above 64 KB and confirm they are rejected.
7. Send an unknown event type and confirm it is rejected.

## Evidence Matrix

| Area | Evidence |
| --- | --- |
| Pairing | matching key-bound emoji/numeric code, paired device stored |
| Calls | macOS native notification appears |
| Messages | reply action creates `message.reply`; Android validates and executes live reply route |
| Clipboard | clipboard event writes through adapter |
| Web | `http`/`https` only |
| Security | signed envelope tamper test fails closed |
| Release | Android APK build and `PlinkMac.app.zip` bundle export exist |
