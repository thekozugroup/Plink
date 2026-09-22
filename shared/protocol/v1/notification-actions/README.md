# Notification actions v1

This extension carries Android notification buttons over the existing authenticated
version 1 envelope. Payload values remain scalar for compatibility with old peers.
The source app's `PendingIntent` and `RemoteInput` result key never leave Android.
Fixtures use synthetic identities and content only.

Android advertises `actionsVersion = 1` in `message.received`, with a fresh
`actionsSession` UUID for the current admission. Mac sends
`notification.actions.enable` only after this authenticated offer. Android
acknowledges that exact session before Mac may invoke v1 actions. Negotiation,
commands, and executable capabilities are memory-only and never retried
implicitly. An old peer keeps the existing safe single-text Reply behavior.

Each offer includes integer `actionsEpoch`, `actionsRevision`,
`actionsExpiresAtMs`, `actionsCount`, and `actionsOverflowCount`. Action slots are
contiguous `action0` through `action9`, in source order. Each includes `Label`,
`Kind`, and `AuthenticationRequired`; executable `invoke` and `text` slots also
include an opaque `Token`. Text slots can include `InputLabel`. `Destructive`
comes only from the source DELETE semantic. A `phone` slot contains a `Reason`
and no token. Missing intent, data input, choice-only input, multiple input
fields, or invalid labels require explicit phone handling.
Immutable text PendingIntents also require the phone. On API26–30, text actions
use this conservative fallback because the public mutability check is unavailable;
ordinary no-input actions remain supported.

Mac uses native `UNNotificationAction` or `UNTextInputNotificationAction`, retaining
call categories. The operating system controls which buttons fit in a compact
notification. Overflow and unsupported input must be explained rather than
silently executed or mislabeled as full parity. Invalid v1 descriptors leave the
ordinary notification text readable without enabling their actions.

`notification.action` includes the negotiated session and epoch, original
`sourceEnvelopeId`, `packageName`, `notificationKey`, `actionIndex`, and
`actionToken`. A text action includes the exact submitted `text`; an ordinary
button does not invent input. Android validates the authenticated peer, current
session/listener, feature consent, notification version, selected capability, and
expiry under its dispatch lock. Authentication-required actions independently
check the owning Android user/profile lock immediately before dispatch. Mac
unlock alone is insufficient. Unknown or locked state cannot execute the action.

Capabilities expire after at most ten minutes. Updates, removal, feature Off,
listener retirement, peer switch, and reconnect revoke affected capabilities.
The legacy Reply alias and v1 token share a single execution claim. Once an
invocation is attempted, canceled intents or lost acknowledgments do not restore
it. A new listener/session may reconcile actual active notifications, protecting
snapshots against concurrent changes; cached durable previews never restore
capabilities.

Successful `notification.action` acknowledgment uses `status = dispatched`, which
means Android accepted the PendingIntent dispatch, not that a recipient received
a message. Enable acknowledgment uses `status = enabled`. Outcomes bind the
original command `eventId`, `action`, `actionsVersion`, and `actionsSession`.
Errors use fixed user-safe codes, including `phone_locked`, `stale_action`,
`action_expired`, `actions_disabled`, `action_not_enabled`, `unsupported_input`,
`action_canceled`, and `invalid_action`. Missing outcomes remain unconfirmed.

Bounds: ten displayed slots; 128 live notification sets/category shapes; 1,280
live tokens per peer; 128 Unicode scalars and 512 UTF-8 bytes per label; 4,000
UTF-16 code units per reply; 64 KiB per encoded envelope. Counters are integral
JSON tokens from zero through 9,007,199,254,740,991; epoch and revision start at
one. Boolean, decimal/exponent, string, and overflowing counter forms are invalid.
The integer token `-0` means zero and remains subject to each field’s lower bound.
Session and action tokens are canonical lowercase UUIDv4 values. Tombstone and
revision state must remain bounded without allowing an older entry to regain
execution authority.

`v1-cases.json` is a handwritten shared parser oracle. `rawEnvelope` preserves
numeric spelling; `valid` describes the relevant extension/command, not whether
an invalid extension's ordinary preview should be dropped. Runtime authority,
lock checks, replacement races, and actual Android dispatch require separate
production-path tests. Passing vectors alone does not prove native presentation
or real messaging-provider behavior.

`android-produced-offers.json` contains exact, unnormalized JSON captured from
the isolated Android framework checks, including delayed removal events. The Mac
tests pass these through the production envelope decoder and action-offer parser.
This interoperability capture supplements the independent handwritten oracle;
it does not establish native Notification Center presentation or hardware behavior.
