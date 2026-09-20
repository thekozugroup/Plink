# Feature Parity

Plink does not claim full Apple Continuity parity. This table records current implementation and verification boundaries.

| Capability | Current state | Verification boundary |
| --- | --- | --- |
| Local pairing | Implemented | Fresh pairings use security version 2 after two-sided code/consent confirmation. Legacy records and keys are preserved as version 0 but are not activated; re-pair each device. |
| Call controls on Mac | Experimental native HFP controller | Real carrier-call answer, decline, and hangup require hardware evidence. |
| Laptop call audio | Experimental route control | SCO connection does not establish two-way laptop microphone/output speech. Real two-way speech testing remains open. |
| Message reply | Inbound Android reply server validates one-time, origin-bound free-form `RemoteInput` routes | Four Pixel synthetic checks passed: one-time delivery with reuse rejection, replacement revocation, data-only rejection, and authentication-required rejection. Native Notification Center delivery to the original conversation/recipient remains open. |
| Battery and device status | Android collector implemented | Real paired-device continuity pass remains open. |
| Media state and controls | Android `MediaSession` collector implemented | Real paired-device continuity pass remains open. |
| Text and URL handoff | Android share target and inbound handoff implemented | Real paired-device continuity pass remains open. |
| Clipboard | Existing continuity path | Real paired-device continuity pass remains open. |
| Background connection | Optional UI-controlled foreground service implemented with application-owned session controller | Requires a paired Mac and notification permission. Emulator UI and explicit failure feedback are verified; physical restart, process recreation, and Doze acceptance remain open. |
| File transfer | Bounded bidirectional transfer implemented over the existing authenticated paired transport; Files defaults off | Explicit native file selection/receive consent; 16 MiB file limit, 32 KiB chunks, one active transfer per peer, no resume. Core tests and ten encrypted emulator/Swift transfers pass at 0, 1, 32,768, 32,769 and 16,777,216 bytes in both directions, with real I/O, SHA-256/byte equality and staging cleanup. Native picker completion and physical-device acceptance remain unverified. |
| Instant Hotspot | Unimplemented requested scope | Implementation required. |
| Continuity Camera | Unimplemented requested scope | Implementation required. |
| Screen mirroring | Unimplemented requested scope | Implementation required. |

Checkpoint 2's canonical gate, [verification-2-final-rerun.log](evidence/2026-09-20/verification-2-final-rerun.log), exits 0 and records 131 Android tests and 101 Swift tests (48 XCTest + 53 Swift Testing) passing; Android lint reports 0 errors and 32 warnings. File policy coverage includes 145 shared vectors, 63 preserving exact raw JSON. These counts establish automated checks, not complete feature acceptance. The final encrypted-file run passed all ten bounded transfers, exit 0. Its [capture summary](evidence/2026-09-20/files-capture-summary.json) reports 1,052 frames per direction, maxima of 58,910/58,903 bytes (Android-to-Mac/Mac-to-Android), no plaintext-marker matches, no unexpected outer fields and no capture errors. The [Mac](evidence/2026-09-20/files-mac-roundtrip.log) and [Android](evidence/2026-09-20/files-android-roundtrip.log) logs are published. The [independent integration review](evidence/2026-09-20/independent-integration-review.json) verifies raw capture and source/binary hashes. After an unexplained emulator exit following the file pass, the same task-owned AVD was restarted; [reply regressions](evidence/2026-09-20/replies-android-roundtrip.log) pass on unchanged binaries. These results do not establish complete file-transfer acceptance or native/physical-device behavior.

File sends require explicit selection; Mac uses `NSOpenPanel`/`NSSavePanel`, while Android receives through a notification-bound consent flow and `ACTION_CREATE_DOCUMENT`, and sends a granted shared URI after confirmation. Receivers verify staged size and SHA-256 before export; sender success requires the receiver's saved result. Transfer state is session-bound, cancels on disconnect or revocation, and is not a durable notification outbox item. Limits remain 60 seconds for an offer, 30 seconds of inactivity, and 300 seconds overall. These are implementation constraints, not claims of completed picker, permission, or filesystem-failure acceptance. Source/evidence mapping: [checkpoint 2](evidence/2026-09-20/README.md).

The checkpoint 2 emulator screenshots show the previous supporting-guidance ellipsis corrected at 1.5× font scale. Existing reduced-motion navigation footage is bounded visual evidence. The [later UI report](evidence/2026-09-20/ui-final-evidence-2.json) shows the Settings title/content overlap corrected in the captured states and lower controls reachable. Its installed/local APK hashes match, but that APK predates the final URI-guard change; unchanged UI source does not establish later-binary behavior. No active file-transfer progress or new final navigation video is established. The [final tested APK capture](evidence/2026-09-20/verified-apk-ui.json) confirms Settings guidance wrapping but exposes a clipped Connection Stop label at 1.5×; that defect remains open. TalkBack, physical-device accessibility, and complete visual acceptance remain open.

The Mac session is currently locked (CUA confirmation), so native Mac UI verification remains blocked. Release signing, macOS notarization, and human hardware testing remain open. Evidence: [2026-09-20 checkpoint](evidence/2026-09-20/README.md); [prior checkpoint, unchanged](evidence/2026-09-19/README.md).

See the [development audit](development-audit-2026-09-19.md) for implementation and test boundaries.

## Licensing

The Android distribution is GPL-3.0-or-later because it includes Tomato-derived UI. The independent Mac distribution remains MIT-licensed. Google Sans Flex assets are licensed under SIL Open Font License 1.1. See `android/NOTICE.md` and `third_party/` notices.
