# Plink

Pixel-to-Mac continuity with native Android and macOS apps.

## Current capability

- Two-sided, authenticated pairing consent with code comparison.
- Android notification mirroring and a validated inbound reply server for eligible free-form `RemoteInput` actions.
- Android battery and media collectors, plus text and URL share handoff in both directions.
- Bidirectional encrypted file transfer with explicit consent, native file selection, a 16 MiB limit, and verified saved results.
- Explicit Android background-connection control backed by an application-owned foreground service.
- Native macOS call controls through an experimental Bluetooth HFP controller.
- Tomato-derived Android Compose UI under GPL-3.0-or-later.

Fresh pairings use durable transport security version 2. Existing legacy pairing records and keys are preserved, but default to security version 0 and are not activated automatically; re-pair each legacy device.

The Mac call UI can request answer, decline, hang up, audio-route, and mute actions. Real cellular-call control and two-way laptop microphone/output speech remain unverified on hardware. A connected SCO route alone does not verify two-way laptop audio.

Four Pixel synthetic `RemoteInput` checks passed: one-time delivery with reuse rejection, notification-replacement revocation, data-only `RemoteInput` rejection, and authentication-required action rejection. They do not prove that a reply started in macOS Notification Center reaches the original conversation or recipient. See the [development audit](docs/development-audit-2026-09-19.md).

## Further integrations

- Screen preview uses explicit Android 14+ capture consent, encrypted bounded JPEG transport, and a native Mac window. A synthetic emulator-to-Mac stream passes; native window behavior and physical-device acceptance remain pending.
- Pixel USB webcam preview provides external camera selection, explicit camera permission, and a native Mac preview. Controller regressions pass with a fake camera driver; physical UVC behavior, native rendering, and actual camera release remain pending.
- Instant Hotspot, wireless Continuity Camera, a virtual webcam for other Mac apps, and remote screen input remain open.

Background connection is an explicit optional Android UI switch. Foreground-service ownership is implemented and requires notification permission plus a paired Mac. Physical restart, process recreation, and Doze acceptance remain pending; Plink does not promise delivery in every background condition or claim full Apple Continuity parity.

## Evidence

Development evidence includes [checkpoint 4 screen/webcam development and final capture checks](docs/evidence/iteration-4/README.md), [checkpoint 3 reply/call corrections and Android design checks](docs/evidence/iteration-3/README.md), the [checkpoint 2 file transfers](docs/evidence/2026-09-20/README.md), and the [earlier native Mac dashboard](docs/evidence/2026-09-19/README.md).

Checkpoint 4 passes 148 Android tests and 158 Swift tests (54 XCTest and 104 Swift Testing), with 0 Android lint errors and 35 warnings. A consented emulator screen stream produces six distinct test frames through the encrypted transport and Mac decoder; projection and owned test state cleanup pass. The encrypted reply harness exercises actual synthetic RemoteInput delivery, exact Unicode/whitespace preservation and final-dispatch revocation. Checkpoint 2 separately verified ten encrypted file transfers across both directions and five size boundaries. Native notification interaction, physical-device behavior, and full hardware/accessibility acceptance remain open. See the [feature inventory](docs/feature-parity.md) and [manual acceptance plan](docs/manual-test-plan.md).

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
