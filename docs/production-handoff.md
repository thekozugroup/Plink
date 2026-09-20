# Production Handoff

## Open release work

- Configure Android release signing credentials.
- Sign, notarize, and staple the macOS app with a Developer ID.
- Complete paired Pixel/Mac tests for call controls, real cellular two-way laptop audio, and native macOS Notification Center replies to a controlled recipient.
- Complete physical Android restart, process recreation, and Doze acceptance for the implemented foreground-service ownership path.
- Complete the matching-build visual and assistive-technology checks. Checkpoint 3 corrects the Connection Stop/Scan width at 1.5× font scale; this does not establish complete layout, motion or accessibility acceptance.

Legacy pairings use security version 0. Preserve their records and keys, but do not activate them automatically: re-pair every existing device to create a security-version-2 pairing.

Checkpoint 3 passes 132 Android tests and 114 Swift tests (54 XCTest and 60 Swift Testing), with 0 Android lint errors and 32 warnings. It strengthens final reply authorization, bounds Bluetooth execution and removes stale call controls. Its [evidence](evidence/iteration-3/README.md) includes exact-text synthetic RemoteInput checks and final-dispatch revocation scenarios. Checkpoint 2 (`c270fb9`) separately passed ten bidirectional encrypted file transfers; its [evidence](evidence/2026-09-20/README.md) remains bound to that earlier build. These counts do not establish full product or accessibility acceptance. Use the [manual acceptance plan](manual-test-plan.md) for exact prerequisites, actions, observations, ownership, and cleanup.

## Required hardware pass

1. Pair Pixel and Mac through the two-sided consent and matching-code flow.
2. Grant ordinary Android and macOS OS permissions needed for the selected capabilities.
   Enable the optional Android background-connection switch, restart the app and device, exercise process recreation, and test an appropriate Doze interval. Record recovery and delivery behavior; current evidence does not establish Doze delivery.
3. Confirm real Android notification mirroring.
4. Send a reply from macOS Notification Center and verify Android applies it to the originating conversation and the controlled recipient receives it.
5. Place a controlled cellular call. Verify answer, decline, hangup, and a two-way laptop microphone/output spoken-phrase check without phone acoustic leakage.
6. Verify battery, media, text, and URL handoff on the paired devices.

The existing four Pixel synthetic `RemoteInput` checks cover one-time delivery with reuse rejection, notification replacement revocation, data-only `RemoteInput` rejection, and authentication-required action rejection. The emulator integration harness also verifies filesystem-backed sequence/replay persistence across store recreation and an encrypted Android-Swift reply/execution acknowledgment. These checks do not replace the Notification Center recipient test or physical restart/Doze acceptance. See the [development audit](development-audit-2026-09-19.md).

## Android release

Set one of each pair before building:

- `PLINK_ANDROID_KEYSTORE_PATH` or `plink.android.storeFile`
- `PLINK_ANDROID_KEYSTORE_PASSWORD` or `plink.android.storePassword`
- `PLINK_ANDROID_KEY_ALIAS` or `plink.android.keyAlias`
- `PLINK_ANDROID_KEY_PASSWORD` or `plink.android.keyPassword`

```sh
./gradlew --project-dir android :android:assembleRelease
```

## macOS release

Set `MACOS_CODESIGN_IDENTITY`, `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID`, and `MACOS_NOTARY_PASSWORD`.

```sh
./scripts/package-macos.sh
./scripts/notarize-macos.sh build/PlinkMac.app.zip
```

## Licensing

Ship Android GPL-3.0-or-later notices with Tomato-derived UI and the Google Sans Flex OFL notice. Keep the independent Mac distribution under its MIT notice.

## Evidence

[Development checkpoint, 2026-09-19](evidence/2026-09-19/README.md).
