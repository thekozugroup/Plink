# Plink

Pixel-to-Mac continuity, built with native Android and native macOS apps.

## What It Does

- Pairs a Pixel and Mac on the local network with matching emoji confirmation.
- Mirrors call and message events to macOS as native notifications.
- Sends message replies from macOS back to Android when Android exposes a safe reply route.
- Models clipboard, file, web, device, battery, and media handoff events.
- Shows a macOS menu bar companion and a Google-style Android companion app.

## Reality Boundary

Plink uses public Android and macOS APIs. It cannot clone Apple private Continuity services such as iPhone cellular audio relay, iCloud identity relay, or private Messages relay. It implements the closest public-API equivalent and documents each gap.

## Project Layout

- `android/`: Kotlin Jetpack Compose Pixel companion.
- `macos/`: SwiftUI/AppKit macOS menu bar companion.
- `shared/`: Protocol fixtures and cross-platform examples.
- `docs/`: Architecture, research, parity, release readiness, and manual test notes.
- `scripts/verify.sh`: Local verification gate.

## Build And Test

Android:

```sh
./gradlew :android:lintDebug :android:testDebugUnitTest
```

macOS:

```sh
cd macos
swift test
swift build
```

Everything:

```sh
./scripts/verify.sh
```

macOS local-test package:

```sh
./scripts/package-macos.sh
```

The script prints the strict-verified app path and exports `build/PlinkMac.app.zip`.

## Release Status

This repo is a verified foundation build. Public end-user release still needs:

- real Pixel plus Mac E2E test evidence
- Android release signing credentials
- macOS Developer ID signing and notarization
- passing GitHub Actions after push

See `docs/release-readiness.md`.

## Permissions

Android users must explicitly enable capabilities:

- Notification listener for notification and message mirroring.
- Notification reply actions for supported app replies.
- SMS/default SMS role only for a future direct-SMS mode.
- Accessibility or share sheet for clipboard automation.
- Optional Shizuku for power-user privileged paths.

macOS users must allow:

- Notifications for native call/message alerts.
- Local network access for device pairing.
- Pasteboard/file access only for enabled handoff features.
