# Checkpoint 4 evidence

This iteration adds consented screen preview and native Pixel USB webcam preview, repairs Android Settings surfaces, and tightens capture lifecycle and queue ownership. Complete Pixel/Mac acceptance remains open.

## Screen transport

The [final matching-build screen run](screen-final-rerun/final-result.json) passes a real Android MediaProjection capture on the owned API-36 emulator, the paired encrypted transport, and native Mac image decoding. Six decoded frames have six distinct pixel hashes and a moving marker. [Decoded pixels](screen-final-rerun/screen-frames/decoded-pattern-6.png) show the synthetic test pattern. The [manifest](screen-final-rerun/manifest.json) binds source and binaries for that run. The run includes the final lifecycle and codec corrections. Seven frames decoded overall; six contained the synthetic pattern, with five distinct marker observations. Maximum JPEG size was 37,019 bytes.

Consent was granted through Plink Share and the normal Android system dialog, selecting the emulator's entire screen. No consent token or permission was injected. The harness confirms projection/service shutdown, original feature preferences and transport state, test-package cleanup, and exact owned ADB endpoint cleanup. No physical Pixel was used. No real message or call was sent.

The [initial failed run](screen-initial/final-result.json) is retained: instrumentation accessed application state before Application.onCreate had completed. The test now waits for the application's main thread to become idle. The failure is not counted as a pass.

## Native implementation boundaries

The Mac screen controller and USB camera controller compile and have regression coverage for permission, visibility, stale-generation, cancellation and cleanup states. Camera tests use a fake capture driver. The Mac session is locked, so these tests do not establish native window rendering, permission-dialog behavior, external-camera capture or physical camera release. Real call speech, native Notification Center recipient delivery and hardware acceptance remain open.

Screen media stays in memory and outside the durable outbox. One response is admitted per pull, with bounded JPEG bytes/dimensions, expiry independent of the send queue, and explicit capture consent for each session. The feature provides view-only frames up to 2 fps, without screen audio or remote input. The Android and Mac validators check complete baseline entropy; the Mac also performs bounded native decoding.

## Android design

The [capture record](ui-capture.json) binds normal and 150% text captures in light/dark themes to the installed build. Settings use Tomato-derived typography, segmented surfaces and floating navigation. [Light Settings](settings-light-1.0.png) and [dark large-text Settings](settings-dark-1.5.png) show the corrected surfaces and wrapped text. These are unpaired emulator screenshots. They do not establish exact motion equivalence, TalkBack support or physical accessibility. All checked emulator display settings were restored; the temporary UI hierarchy file was removed.

The [canonical build](verification-4-final.log) exits 0: 148 Android tests and 158 Swift tests (54 XCTest, 93 Core Swift Testing, 11 Mac Swift Testing), with 0 Android lint errors and 35 warnings. [Build details](build-verification.json) preserve prior failures and their corrections. The [source/binary manifest](verification-manifest.json) binds final outputs. The [encrypted reply regression](reply-bound/android-roundtrip.log) verifies actual synthetic RemoteInput execution once, exact Unicode preservation, replay state and injected authorization revocations; [owned cleanup](reply-bound/host-cleanup.json) passes. No real recipient was contacted. The file-transfer size-boundary harness was not rerun for this checkpoint; checkpoint 2 retains that evidence with its earlier binaries.

A [consent-timeout run](screen-final/final-result.json) is retained separately. The operator completed the system dialog after the 60-second request deadline. Capture did not start, and projection/service/app-state cleanup passed. Its aggregate result is correctly failed. The final rerun operated the same normal visible controls within the deadline.

The [independent acceptance review](adversarial-review.json) supports publishing this development checkpoint and found no checkpoint blocker in the reviewed evidence. STAB-01 remains the only complete original acceptance case: 1 of 27. Stability scores 33.33%; the other eight metrics remain 0 under the frozen whole-case rubric, for a weighted evidence score of 2.33%. These numbers measure complete acceptance evidence, not code quality or lines implemented. Original acceptance criteria remain unchanged. Hardware, native UI, exact design/motion/accessibility and parity gaps remain open.

[Cleanup status](cleanup-status.json) records removed scratch and retained resources for ongoing development. Final project cleanup is not yet complete; the task-owned emulator and reference artifacts remain in use.

The review recorded two provenance limits. Subsequent [package provenance](package-provenance.json) records the packaged Mac executable, ZIP and resources, verifies copied resource bytes, and passes local signature verification. It does not establish Developer ID/notarization or native app behavior. A [fresh reply run](reply-bound/final-result.json) binds installed app, test APK, receiver and source before execution, then verifies all hashes unchanged after the passing roundtrip. The original review and earlier reply run remain unchanged.
