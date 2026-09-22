# Iteration 13: saved phones, connection dashboard, and calls

The Mac dashboard now uses a tall layout with a large device circle, persistent Wi-Fi and Bluetooth status, and a primary action for the current connection state. Saved phones can be selected or unpaired from Plink. Grouped settings use native SwiftUI controls and materials; reduce-transparency and contrast settings are respected. The compact native menu remains.

Unpairing revokes the exact saved peer/session before cleanup. It removes Plink's association and connection metadata without deleting the macOS Bluetooth bond. A retained non-secret revocation marker prevents stale saved metadata from restoring trust after a crash. Inert replay counters remain. If the key was already missing, an inaccessible connection-cache entry may remain and the app reports that condition. Inactive-phone cleanup preserves the current phone's call controls and reconnect behavior. Keychain work releases the metadata lock while mutation ownership and exact-record revalidation remain enforced.

Initial Bluetooth call setup now retains the explicit fresh-pairing request while the previous phone's native connection finishes disconnecting. It opens the chooser once after ownership settles. Restore and background reconnect do not create a new setup request, and a name match does not silently associate a Bluetooth phone.

A compact native SwiftUI call panel provides answer/decline, mute, audio routing, and hangup for supported observed call states. Its static waveform indicates a Bluetooth audio connection; it is not a measured audio waveform. The timer starts when an active call is observed. Lock/sleep/session changes suppress the panel immediately, and duplicate call notifications are suppressed without changing ordinary message replies.

## Verification

The final full verification script passed **478 unit tests: 207 Android and 271 Swift** (64 XCTest, 83 app Swift Testing, and 124 core Swift Testing), Android lint/builds, and signed Mac packaging. Earlier intermediate compilation failures were corrected before this gate.

The package was installed at `/Applications/PlinkMac.app` after the Pixel reported idle call states. The Pixel then reported READY, clipboard connected, and sync enabled. This verifies ordinary restoration on the combined startup/dashboard build. No display settings changed; the last observed display state was Dozing.

Native computer use still failed with “native pipe closed before response,” including after a reset. The user was asked to remove the OnePlus through the new product control, finish Pixel Bluetooth setup, and provide a dashboard screenshot. Those actions, the native dashboard appearance, and actual carrier call controls/two-way Mac audio remain pending; unit tests do not establish them.

[Call panel design preview](call-design-preview.png) renders the actual SwiftUI view with synthetic incoming/active states and inert actions. It is not a live call screenshot. [Preview provenance](call-preview.json) records its source hash. Temporary renderer source and executable were removed.

## Updated reference

The user supplied [LinkMyMac](https://linkmymac.com/) and a notification screenshot as the next product/design reference. Its [feature guide](https://linkmymac.com/features-guide) states that cellular call audio remains on the phone. Plink retains the requested goal of two-way Mac audio. The latest notification reference places the companion icon on the left and source-app artwork on the right; that work follows this checkpoint. The blank primary notification icon remains unresolved. Camera and screen-sharing features remain outside the current scope.
