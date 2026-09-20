#!/usr/bin/env bash
# Runs isolated synthetic replies or file transfers. Never contacts a real recipient.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${1:?Pass the exact adb serial of the test device or emulator.}"
OUT="${2:-$ROOT_DIR/build/device-verification}"
MODE="${3:-roundtrip}"
if [[ "$MODE" != roundtrip && "$MODE" != files ]]; then
  echo "Mode must be roundtrip or files." >&2; exit 1
fi
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
CAPTURE_PID=""
cleanup() {
  if [ -n "$RECEIVER_PID" ]; then kill "$RECEIVER_PID" 2>/dev/null || true; wait "$RECEIVER_PID" 2>/dev/null || true; fi
  if [ -n "$FORWARD_PORT" ]; then "$ADB" -s "$SERIAL" forward --remove "tcp:$FORWARD_PORT" >/dev/null 2>&1 || true; fi
  if [ "$REVERSED" = true ]; then "$ADB" -s "$SERIAL" reverse --remove "tcp:$REVERSE_PORT" >/dev/null 2>&1 || true; fi
  if [ "$INSTALLED" = true ]; then "$ADB" -s "$SERIAL" uninstall app.plink.android.test > "$OUT/test-package-cleanup.log" 2>&1 || true; fi
  if [ -n "$CAPTURE_PID" ]; then kill "$CAPTURE_PID" 2>/dev/null || true; wait "$CAPTURE_PID" 2>/dev/null || true; fi
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
PHONE_TARGET="$MAC_PORT"
MAC_TARGET="$FORWARD_PORT"
if [[ "${PLINK_CAPTURE_TRANSPORT:-0}" == 1 ]]; then
  if [ -e "$OUT/capture" ]; then
    echo "Use a fresh output directory for a synthetic wire capture." >&2; exit 1
  fi
  python3 "$ROOT_DIR/scripts/capture-synthetic-transport.py" --mac-target "$MAC_PORT" \
    --android-target "$FORWARD_PORT" --output "$OUT/capture" > "$OUT/capture.log" 2>&1 &
  CAPTURE_PID=$!
  python3 - "$OUT/capture/ready.json" <<'PY'
import pathlib, sys, time
ready = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 5
while not ready.exists():
    if time.monotonic() >= deadline:
        raise SystemExit('Synthetic capture did not become ready')
    time.sleep(0.05)
PY
  PHONE_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["android-to-mac"])' "$OUT/capture/ready.json")"
  MAC_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mac-to-android"])' "$OUT/capture/ready.json")"
fi
if [[ "$SERIAL" != emulator-* ]]; then
  "$ADB" -s "$SERIAL" reverse --no-rebind "tcp:$REVERSE_PORT" "tcp:$PHONE_TARGET" >/dev/null
  REVERSED=true
fi
PLINK_DEBUG_SESSION_KEY_BASE64="$SESSION_KEY" \
PLINK_DEBUG_PAIRED_DEVICE_ID=test-pixel PLINK_DEBUG_TARGET_DEVICE_ID=test-mac \
PLINK_DEBUG_RECEIVER_MODE="$MODE" PLINK_DEBUG_RECEIVER_PORT="$MAC_PORT" \
PLINK_DEBUG_REPLY_PORT="$MAC_TARGET" "$RECEIVER" > "$OUT/mac-roundtrip.log" 2>&1 &
RECEIVER_PID=$!
"$ADB" -s "$SERIAL" install -r "$TEST_APK" > "$OUT/test-install.log"
INSTALLED=true
TEST_HOST=127.0.0.1
TEST_PORT="$REVERSE_PORT"
if [[ "$SERIAL" == emulator-* ]]; then
  TEST_HOST=10.0.2.2
  TEST_PORT="$PHONE_TARGET"
fi
"$ADB" -s "$SERIAL" shell am instrument -w -e mode "$MODE" -e macHost "$TEST_HOST" -e macPort "$TEST_PORT" \
  -e replyPort "$PHONE_PORT" -e sessionKey "$SESSION_KEY" \
  app.plink.android.test/app.plink.android.PlinkDeviceTestRunner > "$OUT/android-roundtrip.log"
unset SESSION_KEY
wait "$RECEIVER_PID"
RECEIVER_PID=""
if [ -n "$CAPTURE_PID" ]; then
  kill "$CAPTURE_PID"
  wait "$CAPTURE_PID"
  CAPTURE_PID=""
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["passed"], "Synthetic wire capture checks failed"' "$OUT/capture/summary.json"
fi
grep -q 'PLINK DEVICE CHECKS PASSED' "$OUT/android-roundtrip.log"
if [[ "$MODE" == files ]]; then
  grep -q 'FILE ROUNDTRIP PASSED' "$OUT/mac-roundtrip.log"
  printf 'PASS: synthetic Android–Swift encrypted file transfers in both directions at five byte boundaries.\n'
else
  grep -q 'ROUNDTRIP PASSED' "$OUT/mac-roundtrip.log"
  printf 'PASS: synthetic Android–Swift encrypted reply, actual RemoteInput execution, acknowledgment and one-time route.\n'
fi
printf 'Not tested: pairing UI, Notification Center interaction, actual messaging recipient, cellular calls/audio.\n'
