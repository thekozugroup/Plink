# Native notification reply fixture

Astra decision: use a separate, test-only framework Java app. It supplies a real
Android notification with a free-form RemoteInput action for Plink's existing
notification listener. It does not replace Plink, change its pairing/session,
grant itself notification-listener access, or contact anyone.

Package: `app.plink.fixture.nativecheck`. The sole requested permission is
`android.permission.POST_NOTIFICATIONS`. The APK is debuggable and testOnly,
has no shared UID, service, provider, Internet permission or storage permission,
and disables backup. `FixtureActivity` is exported for explicit ADB/launcher
use. `ReplyReceiver` is not exported; only its explicit mutable PendingIntent
accepts the RemoteInput callback.

Notification: **Plink reply check** / **Reply with testword**. Enter exactly
`testword`, without spaces, in the real Mac Notification Center Reply action.
The receiver counts callback deliveries and exact matches. It never stores or
logs the received text, Intent, Bundle, or exception details. A random run token
rejects delayed callbacks from earlier posts. Reposting starts a fresh run and
resets counts; do not repost before collecting the current result.

## Parent-only device procedure

The parent selects and coordinates the device. No agent has installed or run
this app. Keep the existing production Plink session connected, its Android
notification listener and Messages feature enabled, and Mac notifications
allowed. These are prerequisites, not settings changed by this fixture.

```bash
FIXTURE_SERIAL='<parent-selected-device-serial>'
FIXTURE_APK='/tmp/plink-native-notification-fixture/out/plink-native-notification-fixture.apk'

# Install only this distinct test package. Do not uninstall/reset Plink.
# Deliberately omit -r: an unexpected pre-existing package must not be overwritten.
adb -s "$FIXTURE_SERIAL" install -t "$FIXTURE_APK"
# Android 13+: grant only this fixture's notification permission.
adb -s "$FIXTURE_SERIAL" shell pm grant app.plink.fixture.nativecheck android.permission.POST_NOTIFICATIONS

adb -s "$FIXTURE_SERIAL" shell am start -W \
  -n app.plink.fixture.nativecheck/.FixtureActivity \
  -a app.plink.fixture.nativecheck.POST
adb -s "$FIXTURE_SERIAL" shell run-as app.plink.fixture.nativecheck cat files/result.json
```

Baseline must be `{"count":0,"matchedCount":0,"lastMatched":false}`.
The posting activity finishes immediately after posting; it does not stop or
reset the Plink process. If permission is absent, the explicit POST requests
normal Android permission instead. No consent injection is used by the app.

Use native Mac computer use to open the actual **Plink reply check** notification
and send `testword`. Do not send an ADB broadcast or invoke the receiver directly:
that would bypass the route being verified. Then collect:

```bash
adb -s "$FIXTURE_SERIAL" shell run-as app.plink.fixture.nativecheck cat files/result.json
```

Expected after exactly one successful reply:
`{"count":1,"matchedCount":1,"lastMatched":true}`.
`count > 1` reports duplicate delivery rather than hiding it. The Android
notification is cancelled after a recorded reply; the result remains until STOP.
Pair the result with native Mac action evidence and relevant production Plink
observations. The JSON alone cannot distinguish a Mac reply from an Android
direct reply. This checks a synthetic local recipient through the production
route, not external-recipient delivery, real messaging-app compatibility, or
the complete frozen native notification acceptance case.

## Exact cleanup

Save the result to the parent's evidence location first. Then:

```bash
adb -s "$FIXTURE_SERIAL" shell am start -W \
  -n app.plink.fixture.nativecheck/.FixtureActivity \
  -a app.plink.fixture.nativecheck.STOP
adb -s "$FIXTURE_SERIAL" shell run-as app.plink.fixture.nativecheck ls -la files
# files/active-token, result.json, result.json.bak and result.json.new must be absent.
adb -s "$FIXTURE_SERIAL" uninstall app.plink.fixture.nativecheck
```

STOP cancels only notification 7101 in this package, cancels its current reply
PendingIntent, deletes its channel and private token/result (including atomic
file sidecars), and removes its activity task. It neither clears another app's
notifications nor invokes Plink. Parent verifies the fixture notification is
gone and retains/removes host artifacts according to the checkpoint inventory.
Do not clear global logcat or dump other apps' notifications for this check.

## Source and local build

- `AndroidManifest.xml`: explicit permissions/components and debug-only status.
- `FixtureActivity.java`: POST, permission request, synthetic notification, STOP.
- `ReplyReceiver.java`: private callback, run-token check, fixed comparison only.
- `ReplyTally.java`: count/match-only output and executable host self-check.
- `build.sh`: direct javac/D8/aapt2/zipalign/apksigner; no Gradle or downloads.

```bash
/bin/bash /tmp/plink-native-notification-fixture/build.sh
```

Default tools: existing Homebrew JDK 17 and Android SDK build-tools 36.0.0 /
platform android-36; min SDK 26, target 36. Override `FIXTURE_SDK` or
`FIXTURE_JDK` if rebuilding elsewhere. The debug signing key has a public test
password, is used only for this fixture, and remains under `build/`.

`build.log` and `build-result.json` record host validation. `manifest-inspection.txt`
and `artifact-manifest.json` bind the built artifact to its source. The source
archive excludes the signing key, compiled intermediates, and orchestration
metadata. `.a5c/` contains this isolated build's lifecycle records, not Plink
repository state. `build/` is retained, owned compile/signing scratch; `out/`
holds deliverables. No device/native runtime result is claimed by host checks.

## Clipboard extension (version 2 / 1.1)

The same package preserves POST/STOP and the notification reply behavior. It adds
no permission. CLIP_COPY and CLIP_READ run only when the Activity is resumed and
has window focus, after a 500 ms delay. Clipboard access is cancelled on pause
or loss of focus and rescheduled after focus returns. Already performed access
is not repeated after Activity recreation.

Parent-only install/update (same fixture signing key; do not target Plink):

```bash
FIXTURE_SERIAL='<parent-selected-device-serial>'
adb -s "$FIXTURE_SERIAL" install -r -t /tmp/plink-native-notification-fixture/out/plink-native-notification-fixture.apk
```

For Pixel to Mac, launch the foreground fixture and leave it visible:

```bash
adb -s "$FIXTURE_SERIAL" shell am start -W \
  -n app.plink.fixture.nativecheck/.FixtureActivity \
  -a app.plink.fixture.nativecheck.CLIP_COPY
```

It copies exactly `Plink Pixel clipboard check`, stays for two seconds after
copying, then finishes. The parent verifies the actual Mac clipboard through
the production route. There is no shell/service clipboard injection here.

For Mac to Pixel, the parent copies exactly `Plink Mac clipboard check` on Mac,
allows the production route to deliver, then launches:

```bash
adb -s "$FIXTURE_SERIAL" shell am start -W \
  -n app.plink.fixture.nativecheck/.FixtureActivity \
  -a app.plink.fixture.nativecheck.CLIP_READ
# Read after the fixture has finished (one second after its clipboard read).
adb -s "$FIXTURE_SERIAL" shell run-as app.plink.fixture.nativecheck cat files/clipboard-result.json
```

On a clean first successful match:
`{"count":1,"matchedCount":1,"lastMatched":true}`. Later reads increment count;
matchedCount increments only for an exact match. Compare the count with the
previous result to distinguish a fresh read from a stale file. Null, non-text,
multi-item, whitespace-different, and wrong-direction clipboard values do not
match. Clipboard text is never persisted, displayed, or logged. A failed access
or file write logs only `CLIPBOARD_OPERATION_FAILED`, and does not advance count.
This checks clipboard delivery only when paired with the parent's native action
and route evidence; a matching string alone does not establish its origin.

The existing STOP command additionally deletes `clipboard-result.json` and its
atomic `.bak`/`.new` sidecars. STOP does not read or clear the system clipboard,
so it cannot erase subsequently copied user content. Parent owns synthetic
clipboard cleanup on both systems. No agent installed or ran this extension.

## Exact synthetic clipboard cleanup (version 3 / 1.2)

Install this APK with the same install -r -t command above. Then, before STOP
and uninstall, run:

```bash
adb -s "$FIXTURE_SERIAL" shell am start -W \
  -n app.plink.fixture.nativecheck/.FixtureActivity \
  -a app.plink.fixture.nativecheck.CLIP_CLEAN
```

CLIP_CLEAN uses the existing resumed/window-focused 500 ms access guard. It
calls clearPrimaryClip only when the current clipboard contains exactly one
plain-text item equal to `Plink Pixel clipboard check` or
`Plink Mac clipboard check`. URI, Intent, HTML, multiple items, null, and all
nonmatching text remain unchanged. Android API 26/27 leave the clipboard
unchanged because clearPrimaryClip requires API 28. The Activity finishes
immediately after this check. Logs contain only CLIP_CLEAN_CLEARED,
CLIP_CLEAN_UNCHANGED, or the fixed operation-failure marker; no content is saved.
Clipboard inspection and conditional clearing are adjacent calls within one
foreground callback; Android does not offer an atomic compare-and-clear API.
The parent should avoid concurrent clipboard changes during this short action.

Notification, copy/read, and STOP behavior are retained. The previous physical
clipboard attempts reported by the parent were not passes; this cleanup build
has no new device or clipboard-route acceptance result.
