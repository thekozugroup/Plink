# Iteration 10: Bluetooth calling setup

## Changes and verification

Bluetooth setup now deduplicates paired devices by canonical Bluetooth address. An explicit setup action can select one exact phone-name match; ambiguous, blank or different names retain the native chooser. Both paths share validation and association persistence. Fresh pairing continues into call setup only while the initiating pairing and phone remain current. Saved associations do not depend on display names.

Mirrored call notifications now retain their source peer and notification key. An old call-ending event cannot remove a newer call banner. Session retirement removes keyed and unkeyed mirrored banners while preserving the separate native HFP call context. Android's empty caller fallback now says “Phone call.”

The [full verification command](verification-final.log) passed **202 Android tests and 240 Swift tests**: 54 XCTest unit tests, 62 app Swift Testing tests and 124 core Swift Testing tests. Android debug, release and instrumentation builds passed; lint reported zero errors and 39 warnings. The release Mac bundle packaged successfully. No XCTest UI automation was used. See [verification results](verification-result.json), [source review](astra-review.json), and [build provenance](build-provenance.json).

An initial verification launch failed because a detached child inherited Context Mode's deleted temporary directory. The normal execution runner then completed the full gate successfully on the same frozen source. A reviewer also reported a worker completion race; review disproved it because the gate records confirmation before checking whether the invocation returned. The [corrected independent review](luna-call-audit.json) withdraws that finding. No speculative lifecycle patch was added.

## Physical OnePlus test

The existing Bluetooth bond appeared twice in the Mac catalogue, with one physical address. A private exact-address comparison matched the USB-connected replacement phone. The selected trusted Plink peer had no saved Bluetooth association. Its Plink name and Bluetooth name differed, so the new exact-name shortcut would correctly retain native selection.

A bounded native diagnostic first established HFP service in approximately 1.19 seconds, held it for 12 seconds, then disconnected its own attachment. This was a diagnostic, not production call proof; see [probe results](hfp-probe.json).

Computer use repeatedly failed with `Sky Computer Use native pipe closed before response`, including a fresh session. To test the production saved-association path, the agent verified the active trusted pairing and exact physical bond, confirmed no call was active, stopped only Plink, and added that one association while preserving other preferences. This was [development configuration](production-association.json), **not native chooser verification**.

The rebuilt production Mac app then restored the saved phone and received a successful HFP connected callback about **306 milliseconds** after requesting connection. Android independently reported `HeadsetService` connected with an active headset. At the recorded follow-up 270.6 seconds later, it remained connected with no disconnect callback. The ordinary Plink session also reported READY, with clipboard enabled and connected. See [production service evidence](production-service.json).

The updated Mac app remains running. The existing Android app remains installed; the Android change in this checkpoint is wording only. Pairing, phone settings and user data were preserved. No screen-on or brightness change was made during this verification. The [cleanup record](cleanup.json) confirms removal of owned temporary probes and shutdown of the owned log monitor.

## Remaining evidence

The user was asked to call the OnePlus and answer through the Mac. No result has been received for this checkpoint. Carrier Answer, Decline, End, remote hangup, mute, route switching and two-way laptop audio remain unverified. HFP connection does not establish those behaviors.

Native chooser interaction and first-pair setup remain unverified on hardware. No new screenshot is claimed because computer use failed. Screen sharing and USB webcam remain outside the current scope. Historical acceptance-checker drift remains recorded; this checkpoint does not claim full completion or feature parity.
