# Plink

Pixel-to-Mac continuity with native Android and macOS apps.

## Current capability

- Two-sided, authenticated pairing consent with code comparison.
- Android notification mirroring and a validated inbound reply server for eligible free-form `RemoteInput` actions.
- Android battery and media collectors, plus text and URL share handoff in both directions.
- Explicit Android background-connection control backed by an application-owned foreground service.
- Native macOS call controls through an experimental Bluetooth HFP controller.
- Tomato-derived Android Compose UI under GPL-3.0-or-later.

Fresh pairings use durable transport security version 2. Existing legacy pairing records and keys are preserved, but default to security version 0 and are not activated automatically; re-pair each legacy device.

The Mac call UI can request answer, decline, hang up, audio-route, and mute actions. Real cellular-call control and two-way laptop microphone/output speech remain unverified on hardware. A connected SCO route alone does not verify two-way laptop audio.

Four Pixel synthetic `RemoteInput` checks passed: one-time delivery with reuse rejection, notification-replacement revocation, data-only `RemoteInput` rejection, and authentication-required action rejection. They do not prove that a reply started in macOS Notification Center reaches the original conversation or recipient. See the [development audit](docs/development-audit-2026-09-19.md).

## Requested scope still unimplemented

- File transfer
- Instant Hotspot
- Continuity Camera
- Screen mirroring

Background connection is an explicit optional Android UI switch. Foreground-service ownership is implemented and requires notification permission plus a paired Mac. Physical restart, process recreation, and Doze acceptance remain pending; Plink does not promise delivery in every background condition or claim full Apple Continuity parity.

## Evidence

Development evidence, including the native Mac dashboard, Android emulator UI, and synthetic encrypted roundtrip logs: [2026-09-19 checkpoint](docs/evidence/2026-09-19/README.md).

The latest canonical source gate passed 111 Android tests and 82 Swift tests (31 XCTest and 51 Swift Testing). Android lint completed with 0 errors and 27 warnings. The latest isolated emulator roundtrip passed seven synthetic platform checks. These results are development evidence, not full hardware or accessibility acceptance.

## Build and test

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

All local checks:

```sh
./scripts/verify.sh
```

## Permissions and release work

Enable the Android and macOS permissions required by the capability you choose to use, including Android notification access for mirroring and reply routes. Ordinary OS permission grants require the user's normal system confirmation; no extra Plink approval is required.

Open release work: Android release signing, macOS Developer ID signing and notarization, and real paired-device tests for calls, audio, and Notification Center reply recipient delivery.

## Licensing

Android distributions containing Tomato-derived UI are GPL-3.0-or-later. See `android/LICENSE`, `android/NOTICE.md`, and `third_party/tomato/PROVENANCE.json`.

The independent macOS distribution and original Plink material remain MIT-licensed. Google Sans Flex font assets are under the SIL Open Font License 1.1; see `third_party/google_sans_flex/`.
