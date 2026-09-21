# Checkpoint 6: feature removal and connection verification

The user deferred screen sharing and USB webcam. Their controls, consent launchers, capture service registration, production controller wiring and Mac camera permission are removed. Older saved Android settings cannot reactivate screen sharing. Protocol validation and dormant low-level tests remain; previous screen/webcam evidence is historical. Calls, clipboard, files and connection handling remain in place.

The [full build and test gate](verification.log) exits 0: 183 Android and 191 Swift tests pass. Android lint has zero errors and 39 warnings. Actual packaged manifests and signed Mac entitlements confirm capture/camera access is absent and call microphone access remains. An independent Astra source review found no remaining product entry point.

Bluetooth bond, live call connection (HFP), retry and selector fixes were reviewed. The [final Swift run](bluetooth-final-swift-tests.log) passes all 191 tests, and the [signed package](bluetooth-final-package.log) passes packaging and is installed. Phone association and runtime call audio remain unverified; a saved Bluetooth bond does not establish either.

The isolated direct-LAN file engine passed all ten transfers: payloads of 0, 1, 32,768 and 32,769 bytes and 16 MiB in each direction, with exact byte comparisons and transfer cleanup passing. See the [Android log](alternate-files-lan-android-roundtrip.log), [Mac log](alternate-files-lan-mac-roundtrip.log) and [transfer cleanup record](alternate-files-lan-host-cleanup.json). The USB route has a half-close limitation, but it is not a proven root cause of the earlier failures. These engine checks do not establish live file UI acceptance.

Live clipboard delivery passed in both directions on the OnePlus CPH2749 after a Mac restart, using Shizuku shell temporarily. The original Mac clipboard was restored. The subsequent Shizuku helper-death crash (`ConcurrentModificationException`) was fixed and reviewed by Astra; final Android debug, release, test and lint builds all passed. Repeated live transfers passed in both directions. Reopening Plink retained PID 12514 and connected/READY state, with no AndroidRuntime errors observed. Turning Android clipboard sync off blocked both directions in live checks. The Mac off-toggle remains unverified through its UI.

Android clipboard sync is restored to ON and Shizuku is restored to its original root mode. Phone-to-Mac clipboard requires shell mode and is consequently paused. Plink survived the actual Shizuku server restart with the same process and authenticated connection.

[Home](android-home.png) and [Settings](android-settings.png) show the debug APK on the task-owned emulator. The [connected OnePlus screen](alternate-connected.png) shows the connection content fitting within the circle. Native Notification Center reply acceptance remains unverified because Mac computer use failed with “Sky Computer Use native pipe closed before response.”

[Final cleanup](final-device-cleanup.json) confirms original brightness, timeout and stay-awake settings, screen off, Shizuku root mode, fixture removal and scrcpy termination. See [results and limitations](result.json) and the final [source/binary hashes](source-binary-manifest.json). Android process restart still requires a fresh Mac reconnect; sustained background recovery, native call audio and Notification Center reply remain unverified.

Published logs trim trailing whitespace; original command logs remain in ignored task artifacts.
