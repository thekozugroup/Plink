# Manual acceptance plan

This plan complements the automated checks. A passing build, synthetic reply, or notification screenshot does not establish carrier-call control, laptop speech, recipient delivery, or complete Continuity parity. Record each result against the original acceptance case IDs; pending cases receive no completion credit.

## Prerequisites and ownership

The user owns permission choices, the physical Pixel time slot, and authorization of a controlled caller/recipient. The test operator runs Plink and collects timestamps, screenshots, binary hashes, and observations. A controlled remote participant confirms call audio and message receipt. The independent reviewer checks those records before a case is marked passed.

The Mac must be unlocked. Reserve a short Pixel time slot with any other task using it. Record the Pixel model/Android version, Mac model/macOS version, Plink APK/app hashes, network, and Bluetooth state. Use the matching application and instrumentation builds from one verification run. Never erase device data or contact an unrelated person to complete a test. Record temporary settings before changing them; restore them afterward. Keep the physical display off outside brief required consent/UI steps, and release the Pixel promptly.

## Automated baseline

1. Run `./scripts/verify.sh` and retain its complete output and exit code. It records build-time tool versions and builds Android debug/release/test APKs plus the native Mac bundle.
2. Verify the signed Mac bundle with `codesign --verify --deep --strict build/PlinkMac.app`. Ad-hoc local signing does not establish public-release signing or notarization.
3. On an explicitly selected isolated emulator, install the matching debug APK. Run `PLINK_CAPTURE_TRANSPORT=1 ./scripts/verify-device.sh SERIAL FRESH_OUTPUT_DIRECTORY roundtrip`. This uses synthetic notifications and no real recipient.
4. Run the same script with `files` as the last argument for both-direction file checks at 0, 1, 32,768, 32,769 and 16,777,216 bytes. The production transfer deadline remains 300 seconds; the aggregate harness allows multiple transfers.
5. Retain endpoint logs, capture summaries, source/binary hashes, and independent review. Remove task-owned raw captures after review. Confirm instrumentation-package and ADB-mapping cleanup.

## Direct Wi-Fi comparison for file checks

For the isolated file harness, provide both private IPv4 addresses:

```sh
PLINK_TEST_MAC_HOST=192.168.1.10 PLINK_TEST_ANDROID_HOST=192.168.1.20 ./scripts/verify-device.sh SERIAL FRESH_OUTPUT_DIRECTORY files
```

This sends file traffic over Wi-Fi; ADB only installs and controls the test. LAN mode creates no USB forwarding mappings and cannot be combined with the existing loopback capture mode. Both devices acknowledge each completed transfer before the next begins. The final acknowledgment is required too. This verifies the file engines and bytes, not native file pickers or saved production pairing.

## Bluetooth setup regression checks

Select an already OS-paired phone in Connect Calls: its explicit selection must save the association without pairing again. Drop HFP: Bluetooth paired and Done must remain, while calls show disconnected. Retry after a returned connect timeout; also switch paired peers during that timeout. Old callbacks must not attach the previous peer. A blocked native invocation must still quarantine calling. Actual HFP stability and bidirectional call audio require separate live checks.

## Human-assisted cases

For the bounded Android service check, enable Background connection, force-stop Plink, then open it normally. Observe the saved switch and foreground service before any diagnostic broadcast. Repeat with the switch Off: reopening must not start the service. Separately, with the service running, send the app to the background and kill only its process; record whether Android recreates the service without launching the activity. Service presence alone does not prove an authenticated connection or feature delivery.

For Mac recovery, lock or sleep the Mac, then unlock or wake it on the same local network. Also test an actual network change. Confirm a fresh authenticated connection and ordinary feature delivery without clicking Connect. Cancel during recovery, repeat the environment change, and verify that automatic recovery stays suppressed until explicit Connect. Unit tests with injected lifecycle events do not replace these native checks.

All rows remain pending until actual observations exist. The test operator records evidence; the independent reviewer decides whether every criterion of the corresponding frozen case is satisfied.

| Case | Prerequisite and owner action | Expected observation and evidence |
| --- | --- | --- |
| Pairing and permissions (SEC-01, SEC-03, MAC-02) | User opens both apps on the same network, compares the displayed verification code on both devices, and confirms on each. Test a mismatch/cancel before a successful fresh pairing. Grant only the permissions needed for the selected feature. | Mismatch/cancel never activates a session. Matching two-sided consent activates the intended peer. Denied permission has accurate recovery guidance. Capture both consent states without exposing keys. Legacy pairings require a fresh pairing. |
| Incoming carrier call (CALL-01) | User authorizes a controlled participant to call the Pixel's carrier number. Pair the phone with the Mac's native Bluetooth hands-free controller. Keep Plink in the background. | A native Mac notification identifies the intended call. Answer accepts that exact ringing call once. Confirm the phone and remote participant both observe the state change. A simulated call banner does not pass. |
| Laptop speech (CALL-02) | After answering, select computer audio. Place the Pixel outside useful acoustic range while keeping its connection. User and participant sustain a two-minute exchange and each speak previously unannounced words. | The participant hears the Mac microphone, and the user hears the participant through the laptop output, with intelligible speech in both directions for the two-minute exchange. Record selected routes and both observers' results. An SCO callback or audio-device list does not pass. |
| Call lifecycle/recovery (CALL-03, CALL-04) | Repeat controlled calls for decline, local hang-up, remote hang-up, phone/computer audio changes, a dropped Bluetooth link, and reconnect. Include a second ringing/held call if the controlled setup supports it. | Each action affects only its current call. Stale actions cannot affect a later call. Remote hang-up releases controls, and missing confirmation is reported truthfully. Ambiguous multiple-call states remain safely unavailable. Test recovery after an operation timeout without replaying the action. |
| Native message reply (MSG-01, MSG-02) | Controlled recipient sends a message in the intended supported Android app. User replies through macOS Notification Center, including leading/trailing spaces, tabs, newlines, combining text, and emoji. Repeat with two controlled conversations. | The original conversation receives the exact reply once; the other conversation receives nothing. The remote participant confirms content and receipt. Android action-dispatch acknowledgment alone does not prove delivery. Record messaging app/version and whether the case is SMS, RCS, or another replyable app. |
| Reply revocation (MSG-03, SEC-03) | While a reply is pending, separately replace/dismiss the Android notification, disable Messages, disconnect/revoke notification access, change pairing, and let the route expire. Then reconnect and post a fresh controlled notification. | Old actions never send. Failure feedback is visible. Reconnection creates a fresh working route without restoring or automatically retrying the old token. A current call notification remains present when message history is evicted. |
| Native files (CON-02, SEC-03) | Enable Files deliberately. Select a source and destination through the native Mac/Android pickers. Test both directions, cancellation, denied destination access, disconnect, and an existing destination. | Receive consent precedes transfer. Saved output matches source size/hash. Failure never reports success; an unconfirmed result stays unconfirmed. Cancelled transfers remove owned staging/partial new output. Existing user files are not deleted. No received file opens or executes automatically. |
| Clipboard, links, battery and media (CON-02, CON-03) | Use synthetic text and an innocuous HTTPS URL, then a controlled local media item. Compare live battery/media state and exercise the supported commands. | The intended paired device receives the exact selected data. Links require valid HTTP(S) routing. Controls affect the selected live media session. Feature disable and peer replacement stop access. Restore any temporary clipboard content without writing it into evidence. |
| Background/reconnect (STAB-02, STAB-03) | After user-enabled background connection, run three reconnect cycles including Mac sleep/wake, phone process recreation and network changes; follow recovery with a real call and native reply. Separately run the frozen two-hour background/Doze scenario and 100-notification burst, including permission loss. | The app reports actual connection/capability state, preserves replay protection, recovers permitted sessions, and never resurrects revoked replies or resends a file operation. Record elapsed time, latency, resource use, battery drain, and any OS battery restrictions. Preserve the frozen scenario thresholds and duration. |
| Native Mac and Tomato UI (MAC-01, MAC-02, TOM-01–03) | User/reviewer inspects the real Mac app and Android app in light/dark appearance, normal/large text, normal/reduced motion, keyboard/VoiceOver/TalkBack use, and narrow layouts. Compare the pinned Tomato source and mapped interactions. | Native controls, clear permission states, readable full labels, reachable actions, sensible focus order, and matching documented font/motion parameters. Preserve screenshots and real recordings tied to the tested binaries. A static image cannot prove animation or screen-reader behavior. |
| Further integrations and other Android devices (CON-01, CON-03, E2E-02) | Review the explicit parity inventory, then exercise only integrations available in the current apps on supported hardware. Screen sharing, USB webcam and other missing features are deferred. On a physical non-Pixel Android device, also verify the core carrier call, two-way laptop audio, and native Notification Center reply flows. | Observe the actual advertised capability and its consent/cleanup behavior. USB webcam preview is not wireless Continuity Camera; local-only networking is not Internet tethering; viewing a screen is not remote touch control. Unimplemented paths remain open. |

## Deferred screen and webcam checks

Screen sharing and USB webcam were removed from the current apps at the user’s request. Do not request capture or camera permissions or run their former product flows. Earlier harnesses and evidence are historical; deferred cases remain unverified and receive no completion credit.

## Release and cleanup record

Retain a row for every attempted case: case ID, timestamp, tester/observer, prerequisite state, exact action, expected/actual observation, pass/fail/pending, evidence paths and hashes, and remaining blocker. Do not replace the original criteria with an easier synthetic check.

Before public distribution, validate the Android release identity, Developer ID signing, notarization and a clean-machine installation. Follow `docs/production-handoff.md`; local ad-hoc builds are development artifacts.

At the end of the physical-device slot, confirm display state, restored settings, no task-owned test package or temporary ADB mappings, and removal of task-owned phone files. When development verification is finished, stop only this task's emulator/processes and remove its scratch AVD/reference/capture files. Preserve deliverables, durable evidence, installed application data, shared SDK/Gradle caches, and other tasks' devices/files.
