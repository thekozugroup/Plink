# Checkpoint 21: Notification Center recovery

The user reported a frozen Notification Center. Its CPU diagnostic records
PID 1074 consuming 90 CPU seconds over 90 seconds from 09:58 to 09:59:30 EDT on
September 22. The sampled stack is in Apple's view layout and keyboard-focus
code. It does not identify a specific fixture view or establish the cause.
The recorded stall began before the test extension's expiry callback.

The exact user-owned process received SIGTERM; macOS launched PID 38370.
The replacement was sleeping at 0.0% CPU more than eight minutes later.
Computer use could read its Date widget, but the notification panel's usability
still requires confirmation. No notification database, cache, production
preference, or phone setting was changed.

The isolated notification test app and its extension are absent, with no matching
PlugInKit registration. Further live test notifications remain suspended.
Production Plink's generic icon remains unresolved. The recovery action does not
establish a permanent fix for the layout stall.

The last full product gate remains iteration 20: 299 Swift and 207 Android tests,
Android builds/lint, and signed Mac packaging. No production code changed in this
checkpoint; that gate was not rerun and is not reported as new evidence.

## Offline fixture corrections

The archived test fixture now requests dismissal after rejecting an expired or
invalid delivery. Launching it, completing authorization, or handling an old
Reply no longer posts notifications. An explicit native button admits one test
session. Its five-minute observation and ten-minute failsafe start at that click,
so waiting before starting does not shorten the test.

Focused transition checks, six idle-duration cases, seven attachment-scope cases,
and the retained contract/artwork checks passed. Both fixture targets compiled
and passed strict signature validation. The final source archive and every member
hash were independently verified; temporary build directories were removed.
The fixture was not installed, launched, or registered. These corrections address
source-proven lifecycle defects, not the unproven cause of the native focus stall.

The source diff and exact validation record are retained alongside this report.
