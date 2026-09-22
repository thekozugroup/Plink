# Checkpoint 20: observed native notification test

The user's 09:57 screenshots on September 22 show the isolated test app's blue
Plink icon, native notification cards, and native Reply input. This proves the
artwork can render in a fresh notification identity. Production Plink's primary
icon is still unresolved.

The content extension loaded during that first trial but skipped reading its
source-app artwork because `startAccessingSecurityScopedResource()` returned
false. The test now tries the existing bounded file read once regardless of that
Boolean, releasing scoped access only when acquired. File access still depends
on the sandbox; no entitlement, alternate path, or permission change was added.
Seven focused scope cases and the retained fixture checks passed; independent
review approved the correction.

The corrected trial ran from 10:05:36 to 10:10:36 EDT. Both notification requests
were accepted, but no extension execution or Reply callback was recorded. The
corrected read path and artwork appearance therefore remain unverified.

The user's 10:37 screenshot still shows test cards, missing source artwork, an
empty Reply field, and a button overlapping the body. Both test runs had reported
zero owned pending/delivered notifications at cleanup. The late screenshot cannot
be correlated to a live trial; the cause of the retained presentation is unknown.
API cleanup is recorded separately from visual dismissal, which is unverified.

## Verification and cleanup

- Full gate passed: 299 Swift tests, 207 Android tests, Android builds/lint and
  strict signed Mac packaging. The temporary fixture checks were separate.
- No production application source, installed app, phone, or production
  notification setting changed.
- The test app's original Off/Temporary notification settings were restored.
  Its installed bundle, owned scratch, and sandbox event scratch were removed;
  corrected source and sanitized evidence were archived.
- No further timed notification was posted. Neither production icon repair,
  source-app artwork, native reply delivery in this trial, nor cellular call
  audio is accepted as complete.
