# Iteration 7 evidence

Android foreground-service restoration passed its bounded checks. This is **not an overall background or automatic reconnect pass**. The full build gate passed **191 Android and 202 Mac tests**, with **0 Android lint errors and 39 warnings**. Mac recovery code has unit coverage; native wake/unlock recovery remains unverified.

## Android

[Android result](android-result.json) records successful debug assembly, **191 unit tests passed** (zero failures, errors or skips), release assembly, and lint tasks. See the complete [build log](verification.log) and [build result](build-result.json).

- [Before](background-before.json): saved Background connection was On, but the service was absent after relaunch. [After](background-after.json): the same saved On setting restored a foreground service without toggling it.
- [Process recovery](sticky-recovery.json): after Home and an app-UID SIGKILL, the service returned in **1.13 seconds**, without a launch or diagnostic broadcast. This is one observed service recovery, not a guaranteed deadline or proof of encrypted reconnection.
- [Off and relaunch](background-off-relaunch.json): the setting stayed Off and no service appeared. [Original On restored](background-restored-on.json): the foreground service was present again.

The [Android settings screenshot](android-background-settings.png) shows the restored On setting. The [initial installed APK hash](installed-binary-check.json) identifies the build used for the relaunch, Off and process-death checks. A later clean build produced a [different APK](apk-rebuild-correlation.json); it was installed preserving data. The [final installation check](final-android-install.json) confirms the exact gate APK is installed, the saved On service is foreground, and the phone remains Dozing. Off and SIGKILL were not repeated on that clean-build APK.

## Mac recovery and native UI

The Mac patch schedules one guarded discovery attempt after eligible wake, unlock or network changes, preserves explicit cancellation, and rejects stale discovery callbacks. Cleanup and handshake retain the existing 30-second deadline. The full gate passed before a test-only ordering correction; the [focused rerun](mac-recovery-focused-tests.log) then passed all 15 lifecycle tests. Tests cover the production queue, cleanup checks and injected Bonjour callbacks; actual OS lifecycle delivery requires the separate native checks in the manual plan.

The [updated Mac startup check](mac-startup-result.json) reached the native window but remained at **Starting Plink…**. A process sample found saved-pair restoration inside Keychain retrieval. SecurityAgent was running; computer use explicitly refused access to that app for safety reasons. The user must handle its prompt. No pairing reset, secret extraction or fallback UI automation was performed. This does not prove successful reconnection or establish a defect in the new recovery code.

[Native UI attempts](native-ui-attempts.json) verify that macOS notification permission was enabled, including desktop, Notification Center and lock-screen presentation. The notification fixture was posted, but **native reply was not executed**: reply count and matched count were both **0**. CUA could not open the required Notification Center controls; other targets timed out. Plink inspection also repeatedly hit a computer-use service SIGTRAP. No fallback or keyboard-shortcut change was used.

[Sanitized connection observation](before-ax-isolation.json) records a successful Connect action and connected Android state before the accessibility failure. It also records that clipboard sync required Shizuku running as shell; it does not establish working clipboard traffic in that observation. Bluetooth changed from connected to disconnected in native settings; Plink association remained unverified. These observations do not validate the new Mac source.

## Cleanup and provenance

[Cleanup](cleanup.json), rechecked after installation in [final cleanup](final-cleanup.json), matches the [original settings](original-settings.json): brightness 56, manual mode, timeout 120000 ms, and stay-awake 0. The phone was **Dozing**; the fixture and temporary UI dump were absent, and the owned scrcpy process was stopped. Shizuku was observed running as root; unchanged root configuration is parent-reported.

Evidence distinguishes native observations, process diagnostics, unit tests and historical checkpoint 6 results. Published device snapshots omit network addresses and transient process IDs; the build log replaces local user paths. A [sanitized startup stack excerpt](mac-startup-stack.txt) is retained; the full temporary sample was removed.

The original acceptance checker exited **2** before scoring because the device-constraints document no longer matches its frozen hash. Original spec and matrix hashes still match. The original freeze was preserved; current-scope observations are recorded separately. No overall completion score is claimed.

[Independent review](review.json) closes the Mac test finding and keeps the native/runtime and acceptance-integrity limits open. [Source and binary hashes](source-binary-manifest.json) identify the checkpoint.
