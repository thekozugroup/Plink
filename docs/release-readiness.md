# Release Readiness

## Current Status

Plink is a verified public foundation build, not a signed end-user release.

What is ready:

- Android debug/release builds compile.
- Android lint and JVM unit tests pass.
- macOS Swift tests and build pass.
- macOS app is packaged, ad-hoc signed for local testing, strict-verified outside the workspace metadata path, and exported as `build/PlinkMac.app.zip`.
- macOS has both `Network.framework` and Foundation/POSIX secure TCP receivers; the debug receiver defaults to the Foundation fallback for Android-compatible length-prefixed frames.
- Visible manual pairing is implemented as a copy-offer / paste-response flow with key-bound emoji and numeric verification.
- Android includes paired handoff diagnostics for synthetic call, message, and clipboard events without changing Android Settings.
- Pixel-to-Mac encrypted clipboard delivery passed on real hardware through the Foundation fallback receiver on 2026-06-26.
- Installed-app paired clipboard proof passed with `/Applications/PlinkMac.app` and the Pixel app using a fresh shared app-data session on 2026-06-26.
- Local install validation passed: `/Applications/PlinkMac.app` launches, and the Pixel has `app.plink.android` version `0.1.0` installed.
- Shared protocol fixtures validate.
- SMS and phone-state permissions are not requested in the current Android manifest.
- The repo documents public-API limits instead of claiming private Apple Continuity parity.

What still blocks public end-user release:

- Visible manual pairing must get a final human-driven copy-offer / paste-response hardware pass.
- Real notification-listener capture and Android `RemoteInput` reply still need explicit user-granted notification access.
- Automatic nearby discovery/pairing is not implemented yet.
- Android notification forwarding and Android `RemoteInput` replies need device E2E proof.
- Android release APK/AAB needs release signing credentials.
- macOS needs Developer ID signing, notarization, and stapling.
- GitHub Actions must run successfully after pushing the public repo.
- Store distribution needs account-specific privacy, policy, and entitlement review.

## Local Verification

Run:

```sh
./scripts/verify.sh
```

This verifies:

- shared JSON fixtures
- Android debug and release APK build
- Android lint
- Android unit tests
- macOS Swift tests and build
- macOS app packaging and strict codesign verification

## Android Release Requirements

Before publishing:

- Create a release keystore outside the repo.
- Provide signing config through local Gradle properties or CI secrets. Gradle uses these only when all values are present:
  - `PLINK_ANDROID_KEYSTORE_PATH` or `plink.android.storeFile`
  - `PLINK_ANDROID_KEYSTORE_PASSWORD` or `plink.android.storePassword`
  - `PLINK_ANDROID_KEY_ALIAS` or `plink.android.keyAlias`
  - `PLINK_ANDROID_KEY_PASSWORD` or `plink.android.keyPassword`
- Build a signed APK or AAB.
- Run device tests on at least one Pixel with notification listener enabled.
- Verify notification mirroring, text reply, clipboard/web handoff, negative security cases, and permission-denied behavior.
- Review Play policy before adding SMS/default-SMS-role behavior.

## macOS Release Requirements

Before publishing:

- Set `MACOS_CODESIGN_IDENTITY` to a Developer ID Application identity.
- Package using `./scripts/package-macos.sh`.
- Notarize and staple using `./scripts/notarize-macos.sh build/PlinkMac.app.zip` with:
  - `MACOS_NOTARY_APPLE_ID`
  - `MACOS_NOTARY_TEAM_ID`
  - `MACOS_NOTARY_PASSWORD`
- Verify with Gatekeeper on a clean Mac account.

## Current Artifacts

- Android debug APK: `android/build/outputs/apk/debug/android-debug.apk`
- Android unsigned release APK: `android/build/outputs/apk/release/android-release-unsigned.apk`
- macOS local-test zip: `build/PlinkMac.app.zip`
- Installed macOS app: `/Applications/PlinkMac.app`
- Hardware transport proof: `docs/device-test-2026-06-26.md`

## Release Decision

Use this repo as a development/public foundation release until hardware E2E and signing/notarization are complete. Do not market it as full iPhone Continuity parity.
