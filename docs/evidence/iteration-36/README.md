# Companion registration recovery

This checkpoint continues offline validation after the user deferred Pixel checks. It tests Android companion setup recovery; it does not establish native consent, notification-access approval, Continue On interoperability, or call audio.

## Changes

- Preserve an accepted, trusted association when a duplicate or stale callback references its ID, including after a temporary read failure.
- Keep cleanup intent through failed preference commits. An in-memory preference value is not proof that a disk write succeeded.
- Launch a consent request only once. Keep immediate association callbacks and explicit removal working.
- Show recoverable metadata storage/reconciliation errors only for the current authenticated session. Preserve cancellation and pending consent.

Android's [callback contract](https://developer.android.com/reference/android/companion/CompanionDeviceManager.Callback) allows association creation without a preceding consent callback. The persistence tests also model [SharedPreferences updating memory before returning its disk-write result](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/app/SharedPreferencesImpl.java).

## Evidence

The metadata regressions first reproduced six failures in nine tests. All nine pass after the guarded error-reporting change. The final build results, callback regressions, source fingerprint, artifact hashes and independent review are recorded in the adjacent JSON files.

The callback regressions reproduced five failures in 36 tests before the fix. All 45 focused companion tests now pass. The full Android gate passes 312 tests, debug/release/test APK builds, fixtures and the whitespace check. Lint reports no errors and 43 warnings. Manifest inspection confirms the diagnostic receiver is absent from the release APK. Swift is unchanged; its previous checkpoint evidence is retained rather than reported as rerun. Independent review found no must-fix defect in this bounded offline scope.

The debug capability receiver remains restricted to its separate diagnostic process on API 28+, protected by `DUMP`, and excluded from release builds. This checkpoint does not expand the diagnostic to older devices.

## Still pending

No device installation, pairing change, permission change or physical-device test was performed. Pixel companion consent, real notification access and capability reporting need matching-device validation. Two-way cellular audio, notification artwork and consented screen preview remain open requirements.

Metadata publication remains once per authenticated connection, without an application acknowledgment or retry. A failed delivery may require reconnection. Continue On's documented activity export does not establish a supported native Mac receiver; see the [research assessment](../../research.md#android-continue-on-assessment--2026-10-16).

The existing frozen acceptance addendum mismatch remains unresolved. No acceptance criteria or scores are changed by this checkpoint.
