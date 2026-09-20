# Checkpoint 3 evidence

This checkpoint tightens reply authorization and Bluetooth operation ownership, and corrects Android large-text controls and Tomato typography/motion. It does not establish complete Pixel/Mac parity.

## Build and encrypted reply checks

The [canonical build](verification-3-final.log) exits 0: 132 Android unit tests and 114 Swift tests (54 XCTest and 60 Swift Testing), with 0 Android lint errors and 32 warnings. [Build details](build-verification.json) record prior compiler failures and their fixes. The log includes Java, Gradle, Android SDK/build-tools, Swift, Xcode and macOS SDK versions. The instrumentation APK is built by the same gate. [Source and binary hashes](verification-manifest.json) bind the checkpoint.

The [Android log](reply-roundtrip-final/android-roundtrip.log) and [Swift log](reply-roundtrip-final/mac-roundtrip.log) record an authenticated encrypted message/reply/acknowledgment roundtrip on the isolated API-36 ARM64 emulator. The actual synthetic Android `RemoteInput` receives the reply exactly once. Its leading/trailing whitespace, newline, combining accent and emoji are compared as UTF-8 bytes. The [keyless relay summary](reply-roundtrip-final/capture/summary.json) records three encrypted frames, no known plaintext-marker matches and no unexpected outer fields. Device identifiers, sequence numbers and timestamps remain visible metadata. A marker scan is not a cryptographic certification.

The same instrumentation run exercises final-dispatch revocation for listener disconnect/destruction, denied/unknown notification access, feature disablement, session replacement, peer replacement and a command queued before revocation. These are injected lifecycle/permission scenarios using production registry, authority and executor code; they do not prove OS listener lifecycle ordering or permission-dialog behavior. It also checks fresh capabilities after reconnect, single use, canceled PendingIntent rejection and no restoration after uncertain send failure. No real recipient is contacted.

## Correctness changes

- Android reply actions carry listener and session generations. Final authorization and one-time consumption run under the same dispatch lock on the main thread. Revocation clears both route and action registries.
- Mac preflight and payload limits count UTF-16 units, matching Android. Tests accept 2,000 emoji or combining sequences and reject 2,001 before consuming the reply context.
- Mac message bookkeeping bounds and expires message notifications independently of call controls. Startup clears stale OS notifications; orderly Quit explicitly removes the tracked call notification. An uncertain call state also removes controls before notification deduplication. Native disappearance remains unverified while the Mac is locked.
- A Bluetooth deadline distinguishes queued, executing and returned invocations. An executing foreign call is quarantined because Swift cancellation cannot stop it. After a late return, ownership is checked before another native action; an expired Answer cannot proceed to audio transfer. A returned but unconfirmed call action requires reconnect. Tests cover these states, not actual carrier audio.

## Design evidence and limits

Reference images and navigation video in this directory come from the official Tomato v2.0.1 APK. Its publisher digest matches the installed APK and its tag points to the pinned source commit. The publisher binary was not independently rebuilt. Plink uses the bundled licensed font and source-derived components. The [reference capture report](tomato-reference-ui.json) and [matching Plink capture report](plink-ui.json) record exact states, APK hashes and restored settings. [Large-text Connection](plink-gate3-dark-1.5-connection-stop.png) shows the complete Stop label; [large-text Settings](plink-gate3-dark-1.5-settings.png) shows wrapped guidance. [Normal navigation](plink-gate3-dark-1.0-navigation-normal.mp4) contains visible transition content; [animator-zero navigation](plink-gate3-dark-1.0-navigation-animator0.mp4) records Connection to Activity. Independent inspection found the normal clip reaches Activity and Settings; neither clip includes the complete return-to-Connection sequence. Later UI route checks are separate from the recorded frames. These recordings do not establish exact Tomato timing or full reduced-motion accessibility. The captured Settings background remains darker than Tomato and interactive segmented-list shape behavior remains open.

Android screen captures cover unpaired UI states. They do not verify native Mac Notification Center interaction, physical phone background behavior, recipient delivery or accessibility with assistive technology. Checkpoint 2 retains its ten encrypted file-transfer results with its own earlier source and binary hashes; that long file harness was not rerun for this reply/call/UI checkpoint.

No physical Pixel was used in iteration 3. The original acceptance matrix remains unchanged. Hardware-dependent and incomplete criteria stay open; automated test counts are not completion percentages. See the [manual acceptance plan](../../manual-test-plan.md).

## Independent acceptance review

The [independent review](adversarial-review.json) closes STAB-01 (build and regression evidence): 1 of 27 original whole cases. Stability is 33.33%; the other eight metrics remain 0 under the frozen all-criteria-per-case rule. These numbers measure complete acceptance evidence, not implementation quality. Full acceptance remains false. The visible dark-surface mismatch is an open P2 design finding for the next iteration. Native/hardware cases remain pending.
