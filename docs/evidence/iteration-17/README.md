# Checkpoint 17: continuous window material and connection ring

The Mac dashboard now extends its background behind the native title bar using
AppKit's full-size content view and transparent title bar. Only the background
ignores SwiftUI's safe area. The traffic lights remain native, the window retains
its accessible title, and interactive content retains its safe-area layout.
Reduce Transparency uses a continuous opaque system background instead.

The existing 180-point phone circle now has a 12-point ring. Its full accent ring
means the existing Wi-Fi connection is active; it is not a percentage or a claim
that cellular audio works. The centered phone icon and connection text remain.
Increased contrast strengthens the disconnected track. Reduce Motion replaces
the indeterminate progress animation with a static hourglass.

Clipboard, shared links, and file transfers use regular-size native switches.
Their existing bindings and disabled conditions are unchanged. Pairing,
connection, unpairing, and authorization remain explicit actions.

These are appearance changes only. Notification attribution and two-way cellular
audio retain the unresolved limits recorded in checkpoints 15 and 16.

## Verification

The full gate passed 303 Swift tests, 207 Android tests, Android builds/lint,
and the signed Mac package. Native visual verification remains pending.
