# Checkpoint 23: preserve notification ownership during retries

Android could retry a durable notification while its original send was still
running. A retry snapshot captured before successful removal could also enqueue
that notification after the original finished. Sanitized retries omit reply
capabilities, so this race could replace an actionable notification with a
read-only version.

The outbound queue now retains exact request ownership until termination and
rejects snapshots made before a successful send retired. Rejected snapshots
trigger a fresh read so unrelated pending work still progresses. An old canceled
request cannot release a newer request with the same ID. Existing durable
sanitization, feature revocation and clipboard cancellation remain intact.

Four regression assertions failed against the original source. An ownership-only
negative control still failed the stale-snapshot case. Final focused verification
passed 40 tests. Independent review found one progress assertion could pass due
to an unrelated successful send; its corrected version holds that send until the
fresh read is observed. Removing only the refresh signal makes that corrected
test fail. Restoring the final production source passes all 40 focused tests.

The full gate passed 302 Swift and 214 Android tests (516 total), Android builds
and lint, and signed Mac packaging. The subsequent change was test-only; the
production source is byte-identical to the full gate. The corrected focused run
passed; the full gate was not redundantly repeated.

No physical phone installation, real notification action, native notification
post, or message to another person occurred. The user is away; subsequent action
and reply verification uses synthetic data. Mac build 4 remains installed.
Generic left notification icons, the historical duplicate-card cause, native
interaction, and cellular audio remain unverified or unresolved. This checkpoint
does not claim exactly-once delivery across restart or durable removal failure.
