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
| File transfer | Unimplemented requested scope | Implementation required. |
| Instant Hotspot | Unimplemented requested scope | Implementation required. |
| Continuity Camera | Unimplemented requested scope | Implementation required. |
| Screen mirroring | Unimplemented requested scope | Implementation required. |

The latest canonical source gate passed 111 Android tests and 82 Swift tests; Android lint reported 0 errors and 27 warnings. The isolated emulator roundtrip passed seven synthetic platform checks. A 1.5× font-scale check found an open P2: important integration guidance is truncated by a two-line ellipsis. This is not a complete accessibility pass.

Release signing, macOS notarization, and human hardware testing remain open. Current evidence: [2026-09-19 checkpoint](evidence/2026-09-19/README.md).

See the [development audit](development-audit-2026-09-19.md) for implementation and test boundaries.

## Licensing

The Android distribution is GPL-3.0-or-later because it includes Tomato-derived UI. The independent Mac distribution remains MIT-licensed. Google Sans Flex assets are licensed under SIL Open Font License 1.1. See `android/NOTICE.md` and `third_party/` notices.
