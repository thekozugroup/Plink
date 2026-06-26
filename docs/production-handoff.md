# Production Handoff

Plink is ready for a final release pass once user-controlled permissions and signing credentials are available.

## Current Installed State

- macOS app: `/Applications/PlinkMac.app`
- Android package: `app.plink.android`
- Public repo branch: `main`
- Latest local verification command: `./scripts/verify.sh`

## Final Hardware Pass

1. Put Pixel and Mac on the same local network.
2. Open Plink on macOS and confirm it is discoverable.
3. Open Plink on Pixel and tap `Scan`.
4. Tap the discovered Mac offer, or copy/paste the Mac offer manually if discovery is unavailable.
5. Confirm the emoji and six-digit code match on both devices.
6. Tap `Confirm` on Pixel and paste the Pixel response into macOS.
7. Click `Finish Pairing` on macOS.
8. Use Android `Preview events` diagnostics for `Call`, `Message`, and `Clipboard`.
9. Confirm macOS receives native notifications for call/message diagnostics and updates the pasteboard for clipboard.

## Permission-Gated Pass

Only run after explicit approval to change Pixel settings.

1. Grant Android notification runtime permission.
2. Grant Android notification listener access for Plink.
3. Generate a real replyable Android notification.
4. Confirm macOS shows the mirrored message with a reply action.
5. Reply from the macOS notification.
6. Confirm Android executes the `RemoteInput` reply once and rejects replay.

## Android Release

Set one of each pair before building:

- `PLINK_ANDROID_KEYSTORE_PATH` or `plink.android.storeFile`
- `PLINK_ANDROID_KEYSTORE_PASSWORD` or `plink.android.storePassword`
- `PLINK_ANDROID_KEY_ALIAS` or `plink.android.keyAlias`
- `PLINK_ANDROID_KEY_PASSWORD` or `plink.android.keyPassword`

Then run:

```sh
./gradlew --project-dir android :android:assembleRelease
```

## macOS Release

Set:

- `MACOS_CODESIGN_IDENTITY`
- `MACOS_NOTARY_APPLE_ID`
- `MACOS_NOTARY_TEAM_ID`
- `MACOS_NOTARY_PASSWORD`

Then run:

```sh
./scripts/package-macos.sh
./scripts/notarize-macos.sh build/PlinkMac.app.zip
```

## Do Not Claim

- iMessage relay
- cellular audio handoff
- Instant Hotspot
- Continuity Camera
- Sidecar
- private Apple Continuity protocol parity
