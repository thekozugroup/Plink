#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${1:-$ROOT_DIR/build/PlinkMac.app.zip}"

: "${MACOS_NOTARY_APPLE_ID:?Set MACOS_NOTARY_APPLE_ID}"
: "${MACOS_NOTARY_TEAM_ID:?Set MACOS_NOTARY_TEAM_ID}"
: "${MACOS_NOTARY_PASSWORD:?Set MACOS_NOTARY_PASSWORD or an app-specific password}"

test -f "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$MACOS_NOTARY_APPLE_ID" \
  --team-id "$MACOS_NOTARY_TEAM_ID" \
  --password "$MACOS_NOTARY_PASSWORD" \
  --wait

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ditto -x -k "$ZIP_PATH" "$TMP_DIR"
APP_PATH="$(find "$TMP_DIR" -maxdepth 3 -name 'PlinkMac.app' -type d -print -quit)"
test -n "$APP_PATH"

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

rm -f "$ZIP_PATH"
ditto -c -k --norsrc --noextattr --keepParent "$APP_PATH" "$ZIP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

echo "$ZIP_PATH"
