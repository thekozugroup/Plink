# Checkpoint 18: native notification expansion

Apple's current [Tahoe notification reference](https://support.apple.com/en-gb/120684)
shows system-rendered notification cards and an iPhone badge over the app icon.
Plink continues to use UserNotifications for its material, expansion, text and
Reply controls. It does not imitate Notification Center with a separate window.

The user's September 22 screenshots established two separate defects: Plink's
left app icon remained generic, and expanding a message enlarged its source-app
icon into a photo. The bridge had supplied that branding image as a notification
media attachment. It now submits text without that attachment. Sender, message,
app/phone attribution and genuine RemoteInput Reply routing remain intact.

This also removes the compact right artwork and its phone badge. Restoring those
without expanded media remains unfinished. This is an interim correction, not
completion of the requested iPhone-like presentation. Communication intents are
not applied to generic mirrored notifications: Android currently classifies all
non-call notifications as message events, which does not establish a person or
conversation. No cosmetic Mark as Read action or Focus override was added.

## Verification

- 45 focused notification tests passed; independent source review found no blocker.
- Full gate passed: 299 Swift tests, 207 Android tests, Android builds/lint and
  signed Mac packaging. Obsolete attachment-retry tests were removed with that path;
  replacement, stale-completion, dismissal, privacy and Reply checks remain.
- Build 3 was installed after verifying the Pixel had no calls. Bundle identity,
  entitlements and icon assets are unchanged. Version 2 to 3 is release hygiene,
  not an established icon-cache fix.
- The installed process launched, reconnected Bluetooth call control, and logged
  a fresh message submission with no attachment. Computer use failed with
  `Sky Computer Use native pipe closed before response`. Fresh compact/expanded
  screenshots were requested; native appearance remains unverified.
- Before this update, the user's native Mac Reply reached the owned Android
  fixture exactly once and matched `testword`. This proves that earlier live
  reply route, not a new-build reply test.

## Remaining limits

Installed icon metadata, readable assets and strict signature verification agree,
but they do not explain the generic left icon observed by the user. Neither that
icon nor source-app artwork/phone-badge parity is accepted as fixed.

Cellular Mac audio remains unresolved. A separate reviewed metadata-only Android
probe exited 1 without output while the Pixel was idle. It did not allocate audio
endpoints or capture/play audio. The device JAR and owned host build directory
were removed; screen settings were unchanged. No audio success is inferred from
Bluetooth call-control connection or offline tests.
