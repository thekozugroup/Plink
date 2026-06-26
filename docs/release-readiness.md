# Release Readiness

## Current Status

Plink is a verified public foundation build, not a signed end-user release.

What is ready:

- Android debug/release builds compile.
- Android lint and JVM unit tests pass.
- macOS Swift tests and build pass.
- macOS app is packaged, ad-hoc signed for local testing, strict-verified outside the workspace metadata path, and exported as `build/PlinkMac.app.zip`.
- Shared protocol fixtures validate.
- SMS and phone-state permissions are not requested in the current Android manifest.
- The repo documents public-API limits instead of claiming private Apple Continuity parity.

What still blocks public end-user release:

- Real Pixel plus Mac pairing must be tested on hardware.
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
- Provide signing config through local Gradle properties or CI secrets.
- Build a signed APK or AAB.
- Run device tests on at least one Pixel with notification listener enabled.
- Verify notification mirroring, text reply, clipboard/web handoff, negative security cases, and permission-denied behavior.
- Review Play policy before adding SMS/default-SMS-role behavior.

## macOS Release Requirements

Before publishing:

- Set `MACOS_CODESIGN_IDENTITY` to a Developer ID Application identity.
- Package using `./scripts/package-macos.sh`.
- Notarize the exported app archive with Apple notary credentials.
- Staple the notarization ticket.
- Verify with Gatekeeper on a clean Mac account.

## Current Artifacts

- Android debug APK: `android/build/outputs/apk/debug/android-debug.apk`
- Android unsigned release APK: `android/build/outputs/apk/release/android-release-unsigned.apk`
- macOS local-test zip: `build/PlinkMac.app.zip`

## Release Decision

Use this repo as a development/public foundation release until hardware E2E and signing/notarization are complete. Do not market it as full iPhone Continuity parity.
