# Checkpoint 16: launch diagnosis and icon packaging

The reported opening errors were traced to the isolated `PlinkCallKitProbe`,
which crashed in UIKit's missing-scene-lifecycle assertion. The installed
`PlinkMac` process remained running. A fresh sample showed its normal AppKit
event loop and no blocked Keychain read. No production launch defect was
established by those crash reports.

The test fixture now declares a scene and creates its window before its one
synthetic call-report attempt. Its fixed lifetime starts at launch. The corrected
fixture compiled and passed independent source review. It was not relaunched;
its app bundle was removed and its source archived locally. This establishes
neither working CallKit presentation nor call audio.

## Icon packaging correction

The package script previously discarded the icon declarations emitted by
Apple's asset compiler. It now merges the emitted icon keys into the packaged
Info.plist before signing, preserving unrelated metadata and the original ICNS
resource. The actual generated delta is `CFBundleIconFile: Plink.icns → AppIcon`;
`CFBundleIconName` remains `AppIcon`. Both icon resources were valid before this
change. This correction does not establish the cause of the blank notification
icon.

A standalone build first failed inside the Command Line Tools Swift compiler
with signal 6. Packaging now defaults to the installed Xcode toolchain, matching
the repository verification script, while preserving an explicit DEVELOPER_DIR.
The standalone package was rebuilt after this correction.

The updated package passed strict signature verification and was installed
after confirming the Pixel had no active call and normal audio mode. Its new
process reached the normal AppKit event loop without a Keychain wait. The
computer-use bridge still returned `Sky Computer Use native pipe closed before
response`, so window behavior and a fresh Notification Center icon remain
visually unverified. Existing notification rows are not evidence for a newly
installed package.

## Call audio investigation

Read-only Pixel queries established shell UID 2000, genuine shell attribution,
PSTN interception capability, mono 48 kHz telephony input/output ports, and the
presence of Android's call downlink-extraction and uplink-injection factories.
An isolated construction-only Android fixture passed 18 tests with fake endpoints
and synthetic frames, plus offline Java/D8 compilation. It was not deployed.
No audio endpoint was allocated, started, read, or written on the phone. These
are privileged system APIs, not ordinary application capabilities. Their
presence does not prove working audio or the same attribution in Plink's
Shizuku helper.

Bluetooth audio still failed in the preceding real-call tests. A controlled
active-call allocation test and subsequent audible two-way test remain required
before accepting an alternative implementation. No calls were placed, phone
screen settings changed, or audio routes modified in this checkpoint.

## Regression verification

The full repository gate passed 303 Swift tests, 207 Android tests, Android
builds and lint, and the signed Mac release package. This includes no new
real-call or native notification appearance test.
