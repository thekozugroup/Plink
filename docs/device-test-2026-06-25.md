# Device Test Notes - 2026-06-25

## Hardware

- Pixel 10 Pro XL, Android 17, device name `Voyager`
- Mac on LAN address `192.168.50.41`

## Rules Followed

- Android Settings were not opened or changed.
- Notification access, accessibility access, and notification permission were not granted during this run.
- Test pairing was seeded through debug-only app data and temporary Mac environment/keychain data.

## Passed

- Android debug APK installed and launched on the real Pixel.
- Android UI rendered the pairing/permission state without runtime crashes.
- Android error log was clean after foreground launch.
- Android Keystore pairing storage was fixed for Android 17 real-device behavior.
- Raw Pixel-to-Mac LAN socket delivery passed on port `45731`.
- Full local verification passed after the fixes:
  - Android debug/release build
  - Android lint
  - Android unit tests
  - macOS Swift tests
  - macOS build/package

## Failed / Blocked

- The visible Android and macOS pairing UIs are still preview/demo flows; they do not complete real nearby pairing.
- macOS app restore can block on CLI-seeded Keychain secrets, so a debug environment restore path was added for test runs.
- ADB reverse accepted connections but did not deliver payload bytes in this setup.
- Encrypted Pixel-to-Mac clipboard delivery did not complete through the current macOS `Network.framework` receiver during this run, despite raw LAN socket delivery working on the same port.
- Notification handoff and notification reply were not validated because Android notification access and notification permission were intentionally left unchanged.

## Next Engineering Targets

- Replace demo pairing UI with a real pairing exchange between Android and macOS.
- Investigate or replace the macOS `Network.framework` receiver path for device-originated TCP traffic.
- Add an in-app diagnostic screen for local endpoint, listener state, and last transport error.
- Validate notification mirroring/reply only after the user explicitly allows notification access and notification permission.
