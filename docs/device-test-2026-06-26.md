# Device Test Notes - 2026-06-26

## Hardware

- Pixel 10 Pro XL, Android 17, device id `57171FDCQ004EW`, device name `Voyager`
- Mac LAN address `192.168.50.41`

## Rules Followed

- Android Settings were not opened or changed.
- Notification access, accessibility access, and notification permission were not granted during this run.
- Test pairing was seeded through debug-only Plink app data.

## Passed

- macOS app installed to `/Applications/PlinkMac.app`.
- macOS app launched successfully from `/Applications`.
- macOS menu bar app remained running after switching to an AppKit `NSStatusItem` lifecycle.
- Pixel app `app.plink.android` installed and launched.
- Pixel package state showed `versionName=0.1.0`, `versionCode=1`.
- Pixel UI showed the visible `Manual pairing` controls: `Mac pairing offer`, `Import`, and `Confirm`.
- Pixel UI showed the nearby discovery controls: `Scan`, `Nearby scan idle`.
- Tapping `Scan` changed the Pixel UI to `Stop` and `Scanning for nearby Macs`; tapping again stopped discovery and returned to `Scan`.
- Pixel UI showed paired diagnostic controls in `Preview events`: `Call`, `Message`, and `Clipboard`.
- Foundation/POSIX Mac receiver accepted an encrypted Pixel event using Android-compatible length-prefixed socket framing.
- Pixel sent `clipboard.updated` with `source=pixel-debug` and `target=mac-demo`.
- macOS pasteboard updated to `PlinkPixelToMacEncryptedClipboard_20260626T135916Z`.
- Installed-app paired proof passed with a fresh app-data session:
  - Mac app binary: `/Applications/PlinkMac.app/Contents/MacOS/PlinkMac`
  - Pixel id: `pixel-cecf07c65fc020a0`
  - Pixel IP: `192.168.50.98`
  - Mac IP: `192.168.50.41`
  - macOS pasteboard updated to `PlinkInstalledPairedClipboard_20260626T141547Z`.

## Artifacts

- Receiver log: `build/foundation-receiver-device-test-2026-06-26.log`
- Pixel launch screenshot: `build/pixel-installed-after-fallback.png`
- Updated Pixel manual-pairing screenshot: `build/pixel-manual-pairing-2026-06-26.png`
- Updated Pixel manual-pairing UI dump: `build/pixel-manual-pairing-ui-2026-06-26.json`
- Paired diagnostics UI screenshot: `build/pixel-diagnostics-preview-final3-2026-06-26.png`
- Paired diagnostics UI dump: `build/pixel-diagnostics-preview-final3-ui-2026-06-26.json`
- Installed-app paired log: `build/plinkmac-installed-paired-2026-06-26.log`
- Nearby discovery installed screenshot: `build/pixel-nearby-discovery-installed-2026-06-26.png`
- Nearby discovery installed UI dump: `build/pixel-nearby-discovery-installed-ui-2026-06-26.json`
- Nearby discovery scan screenshot: `build/pixel-nearby-discovery-scan-2026-06-26.png`
- Nearby discovery scan UI dump: `build/pixel-nearby-discovery-scan-ui-2026-06-26.json`
- Nearby discovery stopped UI dump: `build/pixel-nearby-discovery-stopped-ui-2026-06-26.json`
- macOS local-test package: `build/PlinkMac.app.zip`

## Remaining Release Blockers

- Visible manual pairing UI is implemented and visible on Pixel, but the full copy-offer / paste-response UI flow still needs a human-driven hardware pass.
- Nearby discovery starts and stops on Pixel; same-network Mac offer discovery still needs a fresh unpaired-Mac hardware pass because the installed Mac restored an existing pairing and did not advertise.
- Notification mirroring and reply require Android notification access and runtime permission, which were intentionally left unchanged.
- Android release signing credentials are still needed for a distributable APK or AAB.
- macOS Developer ID signing, notarization, and stapling are still needed for public distribution.
