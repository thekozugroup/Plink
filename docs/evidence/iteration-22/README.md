# Checkpoint 22: retire late message notifications

A pending macOS notification add could complete after its message was replaced,
removed, dismissed, replied to, or cleared. Plink had already removed the old
request, but its late completion only handled call notifications. The retired
message could therefore remain visible alongside its replacement.

The bridge now remembers whether a submission was a tracked message and removes
a retired request again when its completion arrives. Bookkeeping membership
protects current same-ID replacements, including read-only messages. Unkeyed
notifications keep their existing behavior. Equal text from different keys or
phones is not merged.

The held-completion regression failed in six retirement cases before the fix.
The focused run then passed 36 tests. Independent review verified both the
failure evidence and the final source. Full verification passed 302 Swift tests
and 207 Android tests, Android builds/lint, and signed Mac packaging.

Build 4 is installed at `/Applications/PlinkMac.app` with the same bundle identity.
Its executable hash matches the verified build, and its process remains running.
Computer-use launch timed out after starting the app, so native interaction and
live notification behavior are not accepted as verified. No synthetic native
notifications were posted. Temporary installation and icon-extraction files were
removed; the distribution zip is retained.

## Remaining evidence limits

The user's screenshot shows Notification Center rendering again and two visually
identical recent cards. It does not prove which path produced those cards.
The corrected race is independently reproduced; real Gmail deduplication is not
claimed from this regression.

The installed ICNS resources and named catalog image render the correct blue and
white icon. This rules out blank source pixels, but does not explain Notification
Center's generic left icon. No cache, identity, or toolchain experiment was made.
The previous native focus-layout stall's cause and cellular call audio remain
unresolved. A separate Android retry race is deferred for its own regression and
fix. Group-summary filtering was not changed.
