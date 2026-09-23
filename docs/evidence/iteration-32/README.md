# MPCFW and Apple Continuity source review

MPCFW supplies partial Multipeer Connectivity framing for Logic Remote. It does not implement Apple Account enrollment, cellular audio, screen capture, or macOS notification identity. Its pinned client disables authentication and encryption; no implementation was copied or executed.

The review also distinguishes historical Call Relay packet research, current FaceTime media code, Rapport/Handoff instrumentation, developer-service pairing and Apple TV Companion authentication. None supplies Plink's missing Android cellular downlink and uplink endpoints. See the [research findings and references](../../research.md#mpcfw-and-apple-pairing-research--2026-09-22).

The implementation priority is actual call audio, then screen sharing, then the primary notification icon. Contacts remain deferred. SMS/MMS conversations and a standalone Messages app are outside current scope; existing notification replies/actions remain in scope.

The proposed audio experiment must first establish observable ownership and cleanup of temporary Android audio policies. It would then test distinct generated signals in both directions before any new network transport. Such a result would still need separate cellular-call validation. No endpoint experiment or device operation ran here.

This is a documentation checkpoint. Source review and a whitespace/diff check establish the report's scope, not working media or visual correctness. Product source, installed apps, device settings and notification state were unchanged. Revision pins, source-review limits and checks are recorded in [verification.json](verification.json).
