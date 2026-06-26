# Device Test Notes - 2026-06-26

## Hardware

- Pixel 10 Pro XL, Android 17, device id `57171FDCQ004EW`, device name `Voyager`
- Mac LAN address `192.168.50.41`

## Rules Followed

- Android Settings were not opened or changed.
- Notification access, accessibility access, and notification permission were not granted during this run.
- Test pairing was seeded through debug-only Plink app data.

## Passed

- macOS app installed to `/Applications/PlinkMac.app`.
- macOS app launched successfully from `/Applications`.
- Pixel app `app.plink.android` installed and launched.
- Pixel package state showed `versionName=0.1.0`, `versionCode=1`.
- Foundation/POSIX Mac receiver accepted an encrypted Pixel event using Android-compatible length-prefixed socket framing.
- Pixel sent `clipboard.updated` with `source=pixel-debug` and `target=mac-demo`.
- macOS pasteboard updated to `PlinkPixelToMacEncryptedClipboard_20260626T135916Z`.

## Artifacts

- Receiver log: `build/foundation-receiver-device-test-2026-06-26.log`
- Pixel launch screenshot: `build/pixel-installed-after-fallback.png`
- macOS local-test package: `build/PlinkMac.app.zip`

## Remaining Release Blockers

- Visible nearby pairing UI still needs to use the proven encrypted transport path end to end.
- Notification mirroring and reply require Android notification access and runtime permission, which were intentionally left unchanged.
- Android release signing credentials are still needed for a distributable APK or AAB.
- macOS Developer ID signing, notarization, and stapling are still needed for public distribution.
