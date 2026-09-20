#!/usr/bin/env bash
# Runs synthetic replies only. Never sends to a messaging app or real contact.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${1:?Pass the exact adb serial of the test device or emulator.}"
OUT="${2:-$ROOT_DIR/build/device-verification}"
ADB="${ADB:-adb}"
RECEIVER="$ROOT_DIR/macos/.build/debug/PlinkMacDebugReceiver"
TEST_APK="$ROOT_DIR/android/build/outputs/apk/androidTest/debug/android-debug-androidTest.apk"
PHONE_PORT=45791
REVERSE_PORT=45790
mkdir -p "$OUT"
test -x "$RECEIVER"
test -f "$TEST_APK"
"$ADB" -s "$SERIAL" get-state >/dev/null
if ! "$ADB" -s "$SERIAL" shell pm path app.plink.android | grep '^package:' >/dev/null; then
  echo "Install the matching Plink debug app first." >&2; exit 1
fi
if "$ADB" -s "$SERIAL" shell pm path app.plink.android.test | grep '^package:' >/dev/null; then
  echo "A test package already exists. Preserve or remove it explicitly before this isolated run." >&2; exit 1
fi
if "$ADB" -s "$SERIAL" reverse --list | grep "tcp:$REVERSE_PORT " >/dev/null; then
  echo "Test reverse port is already in use; no mapping was changed." >&2; exit 1
fi
RECEIVER_PID=""
FORWARD_PORT=""
REVERSED=false
INSTALLED=false
cleanup() {
  if [ -n "$RECEIVER_PID" ]; then kill "$RECEIVER_PID" 2>/dev/null || true; wait "$RECEIVER_PID" 2>/dev/null || true; fi
  if [ -n "$FORWARD_PORT" ]; then "$ADB" -s "$SERIAL" forward --remove "tcp:$FORWARD_PORT" >/dev/null 2>&1 || true; fi
  if [ "$REVERSED" = true ]; then "$ADB" -s "$SERIAL" reverse --remove "tcp:$REVERSE_PORT" >/dev/null 2>&1 || true; fi
  if [ "$INSTALLED" = true ]; then "$ADB" -s "$SERIAL" uninstall app.plink.android.test > "$OUT/test-package-cleanup.log" 2>&1 || true; fi
}
trap cleanup EXIT
MAC_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
SESSION_KEY="$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(32)).decode())
PY
)"
FORWARD_PORT="$("$ADB" -s "$SERIAL" forward tcp:0 "tcp:$PHONE_PORT")"
if [[ "$SERIAL" != emulator-* ]]; then
  "$ADB" -s "$SERIAL" reverse --no-rebind "tcp:$REVERSE_PORT" "tcp:$MAC_PORT" >/dev/null
  REVERSED=true
fi
PLINK_DEBUG_SESSION_KEY_BASE64="$SESSION_KEY" \
PLINK_DEBUG_PAIRED_DEVICE_ID=test-pixel PLINK_DEBUG_TARGET_DEVICE_ID=test-mac \
PLINK_DEBUG_RECEIVER_MODE=roundtrip PLINK_DEBUG_RECEIVER_PORT="$MAC_PORT" \
PLINK_DEBUG_REPLY_PORT="$FORWARD_PORT" "$RECEIVER" > "$OUT/mac-roundtrip.log" 2>&1 &
RECEIVER_PID=$!
"$ADB" -s "$SERIAL" install -r "$TEST_APK" > "$OUT/test-install.log"
INSTALLED=true
TEST_HOST=127.0.0.1
TEST_PORT="$REVERSE_PORT"
if [[ "$SERIAL" == emulator-* ]]; then
  TEST_HOST=10.0.2.2
  TEST_PORT="$MAC_PORT"
fi
"$ADB" -s "$SERIAL" shell am instrument -w -e macHost "$TEST_HOST" -e macPort "$TEST_PORT" \
  -e replyPort "$PHONE_PORT" -e sessionKey "$SESSION_KEY" \
  app.plink.android.test/app.plink.android.PlinkDeviceTestRunner > "$OUT/android-roundtrip.log"
unset SESSION_KEY
wait "$RECEIVER_PID"
RECEIVER_PID=""
grep -q 'PLINK DEVICE CHECKS PASSED' "$OUT/android-roundtrip.log"
grep -q 'ROUNDTRIP PASSED' "$OUT/mac-roundtrip.log"
printf 'PASS: synthetic Android–Swift encrypted reply, actual RemoteInput execution, acknowledgment and one-time route.\n'
printf 'Not tested: pairing UI, Notification Center interaction, actual messaging recipient, cellular calls/audio.\n'
