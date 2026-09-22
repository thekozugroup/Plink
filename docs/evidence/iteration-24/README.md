# Checkpoint 24: Android notification actions and native Mac replies

Plink previously exposed one Android free-text Reply action. Other source buttons
were absent, and a reply with several input fields could receive the same text
in every field. Listener/session changes also left old notification capabilities
unusable until another notification update.

The new scalar protocol extension preserves source action labels and order for
up to ten native Mac actions. Plain buttons invoke their original Android
PendingIntent. A supported Reply sends the exact text to its one original
RemoteInput key. Multiple independent Reply actions keep separate authority.
Choice-only, data, multiple-field and immutable text inputs direct the user to the
phone. Additional source actions are explicitly reported as overflow. Native
macOS decides how many buttons fit in the compact view.

Action authority is scoped to the authenticated connection, listener, source
notification and individual action. Current-session negotiation precedes new
commands. Replacement, removal, feature Off, listener retirement and reconnect
revoke affected capabilities. Legacy Reply and its corresponding new action share
one claim. A late metadata-free durable preview cannot replace a newer tracked
v1 notification. Neither failed dispatch nor a lost acknowledgment automatically sends
again. Durable previews strip every action capability.

Android checks authentication-required actions against the owning user/profile
at dispatch. Unknown or locked state fails closed. Android 12/API31 and newer can
use the public PendingIntent mutability check for text replies. On API26–30,
text actions require the phone; ordinary no-input actions remain supported.
This conservative fallback uses public APIs only.

The Mac uses native UserNotifications categories and text-input actions. The
existing call categories remain registered. Action lookup requires the current
presentation and capability; late callbacks cannot revive retired buttons.
An already-dispatched result can still complete after its source notification
updates or disappears. Older results cannot overwrite a newer attempt’s status.
A dispatched acknowledgment means Android accepted the PendingIntent, not that a
message reached its recipient. Missing outcomes are reported as unconfirmed.

## Verification boundary

Shared raw JSON vectors are independent of both platform implementations.
Counterexamples cover malformed metadata, strict integer spelling, Unicode
limits, exact conditional fields, compatibility and canonical tokens. Invalid
optional action metadata keeps ordinary text readable without granting actions.

Framework checks use an isolated, account-free API36 ARM64 emulator. They create
never-posted notifications and package-scoped synthetic PendingIntents, invoking
the actual mapper, action registry and Android RemoteInput/PendingIntent APIs.
These tests do not contact another person or operate a real app notification.
Lock-state cases are injected; this is not hardware/profile authentication proof.
The framework helper does not traverse the production session controller's
ordinary-admission transport path. Deterministic unit tests cover separate
ownership, replacement, expiry and callback races.

The final `./scripts/verify.sh` passed: 242 Android and 323 Swift tests, Android
lint, debug/release builds, instrumentation build and Mac packaging. The rebuilt
APKs passed 11 generic-action and 8 existing reply framework scenarios. Both
platforms consume 105 handwritten wire vectors; Mac additionally accepts 26
exact Android-produced offers. A separate compiled-core check accepted all 1,000
millisecond positions at the exact ten-minute expiry boundary.

Review found and corrected an inconsistent lock order between publication and
dispatch. All three command entry sites now acquire reply authority before the
admission lease, with three deterministic contention/revocation regressions.
The prior durable queue implementation remains unchanged. Independent final
review found no open findings within this iteration's reviewed scope.

Native Notification Center placement, real messaging-provider behavior, Pixel
API37 operation and full paired-device acceptance require later live checks.
The generic primary notification icon and cellular call audio remain unresolved.
No Notification Center extension or icon/cache experiment is part of this change.
Exact totals, source and artifact hashes, and limits are recorded in
`verification.json`. The owned emulator and its data were deleted, as were
temporary helpers and the expanded Mac build app. Distribution ZIP/APKs and
verification evidence remain. The installed Mac app and physical phone were
untouched; installation and live checks wait for the user's return.
