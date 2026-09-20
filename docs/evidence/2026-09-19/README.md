# Development evidence — September 19, 2026

This directory contains actual captures and test results from the development checkpoint, not generated mockups. The evidence is incomplete. A successful test or screenshot must not be read as proof of every continuity feature.

The latest canonical source gate passed 111 Android tests and 82 Swift tests (31 XCTest and 51 Swift Testing). Android lint completed with 0 errors and 27 warnings. These counts cover the source gate only; hardware and accessibility acceptance remain bounded as described below.

## Native Mac dashboard

`mac-dashboard-first.png` captures the running, locally built and ad-hoc signed SwiftUI/AppKit application on macOS 27.0. It shows the unpaired state: no received battery or media data, unavailable sharing actions, Bluetooth setup controls, and denied notification permission. No synthetic call or message was inserted to make the dashboard look connected.

This capture establishes the initial native layout only. It does not establish notification permission, pairing, actual Bluetooth calling, laptop audio, or message delivery. Later captures may show corrections from visual and adversarial review.

## Pixel platform checks

The connected Pixel 10 Pro XL (Android 17, API 37) executed four isolated instrumentation checks:

1. A real Android `RemoteInput` `PendingIntent` delivered synthetic text exactly once; reuse of the route was rejected.
2. Replacing a notification without a reply action revoked its previous reply route.
3. A data-only `RemoteInput` was not advertised as a text-reply route.
4. An action requiring authentication was not advertised as a remote-reply route.

These checks created unposted synthetic notification objects and a test-owned broadcast receiver. They did not contact any person, send through a messaging application, post a user notification, or modify saved pairing records. They do not establish Mac Notification Center interaction or actual recipient delivery.

No screen-timeout or stay-awake setting was changed. The screen was found on after installation/instrumentation and was immediately turned off. An attempted virtual-display recording produced no frames and is not evidence. Further visual checks use an isolated emulator to avoid occupying the shared Pixel.

## Reproducing the isolated roundtrip

After building and installing the matching debug app on an explicitly selected test device:

```sh
./gradlew :android:assembleDebug :android:assembleDebugAndroidTest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path macos --product PlinkMacDebugReceiver
./scripts/verify-device.sh EXACT_ADB_SERIAL
```

The script exchanges a synthetic Android message, a Swift-generated reply, and an Android execution acknowledgment through the production encrypted transports. Android dispatches the reply through a real test-owned `PendingIntent` and checks one-time route enforcement. The script uses temporary port mappings and a random synthetic session key; it removes its test package and mappings. It refuses to replace an existing test package or reverse mapping.

This is a component integration check, not a paired product acceptance test. It deliberately does not exercise human code comparison, the macOS notification interface, a real messaging recipient, or a carrier call.

The emulator roundtrip passed on September 19. Logs are in `emulator-roundtrip/`. Six checks passed: the four reply checks above, actual Android filesystem persistence of sequence/replay state across store recreation, and the encrypted Android–Swift reply/acknowledgment roundtrip. The temporary test package was removed successfully; temporary ADB mappings were absent afterward. The emulator used its `10.0.2.2` Mac host route. An initial ADB reverse attempt timed out and is not counted as a pass.

The latest isolated emulator rerun is PASS7. Its logs are in `checkpoint-1-roundtrip/`, and `checkpoint-1-verification.json` records the matching checkpoint APKs, seven synthetic platform checks, exit code 0, test-package removal, and empty ADB forward/reverse mappings. This latest result does not rewrite or broaden the historical PASS6 scope above, and it is not physical-device or end-to-end product acceptance.

The Android foreground-service ownership path and explicit Settings control are implemented. This checkpoint does not include physical-device restart, process recreation, or Doze acceptance, so it does not establish reliable delivery in those conditions.

## Android visual checkpoint

The six `android-emulator-{connection,activity,settings}-{light,dark}.png` files show the real Compose app in its unpaired state on the isolated API 36 arm64 emulator `emulator-5580`. Each capture was gated on `app.plink.android/.MainActivity` being the top-resumed activity and on destination-specific accessibility text, then inspected as pixels. `android-emulator-settings-background-action-required-light.png` records an explicit background-connection request while unpaired: the switch remains off and the application facade returns visible guidance. `android-emulator-navigation.mp4` is a 7.38-second H.264 recording of the three destinations in dark mode.

The installed debug APK SHA-256 was `0f76dde418645a5bff41cd26c3842f844f69474071c18563afa6e61837a3ea05`; the owned UI source/font bundle SHA-256 was `a1c69005a3e87b732b8b169e0d27491efd3200dda403a16ea6211d642a72c5aa`; the repository HEAD at capture time was `93f61c33a693dddb2f4c05965c3c5f1e615a2399`. The shared typography, rounded groups, and floating navigation derive from the pinned Tomato sources. Disabled settings identify unavailable capabilities rather than simulating integrations. The screenshots show no horizontal clipping at the emulator's default font scale. Permission grants and human TalkBack traversal remain separate acceptance checks.

## Android large-text and reduced-motion checkpoint

`android-emulator-large-text.png` shows the real Settings destination at Android `font_scale=1.5` with `animator_duration_scale=0`. Connection, Activity, and Settings remained reachable through the floating navigation, required destination labels remained present, and UIAutomator reported no text-node bounds outside the 1080×2400 display. The Connection permission cards were reachable by scrolling.

Visual inspection found one unresolved **P2 accessibility issue**: integration summaries still use a two-line ellipsis, and the Clipboard guidance is visibly truncated at “or tap an incomi…” at 1.5×. In the next UI checkpoint, remove the summary `maxLines`/ellipsis constraint so important supporting text can wrap fully. This change is intentionally deferred from the current frozen build. The timed Settings lower-control sweep did not complete, so this checkpoint does not establish reachability for every Settings row. No UI source change was made in the documentation lane. This was not a human TalkBack test, and accessibility-tree presence must not be treated as TalkBack acceptance. The prior emulator settings were restored exactly after the check.
