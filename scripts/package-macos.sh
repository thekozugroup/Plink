#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${PLINK_MACOS_APP_DIR:-${TMPDIR:-/tmp}/plink-build/PlinkMac.app}"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
DIST_DIR="$ROOT_DIR/build"
DIST_ZIP="$DIST_DIR/PlinkMac.app.zip"

cd "$ROOT_DIR/macos"
swift build -c release

rm -rf "$APP_DIR" "$ROOT_DIR/build/PlinkMac.app"
mkdir -p "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/macos/.build/release/PlinkMac" "$MACOS_DIR/PlinkMac"
cp "$ROOT_DIR/macos/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" "$RESOURCES_DIR/PlinkMac.entitlements"
chmod +x "$MACOS_DIR/PlinkMac"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
test -x "$MACOS_DIR/PlinkMac"
test -f "$RESOURCES_DIR/PlinkMac.entitlements"

# Finder/provenance xattrs can be attached by local filesystem tools and make
# strict codesign verification fail even when the signature itself is valid.
find "$APP_DIR" -exec xattr -c {} + 2>/dev/null || true

SIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" \
  "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
codesign -d --entitlements :- "$APP_DIR" >/dev/null 2>&1

rm -f "$DIST_ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$DIST_ZIP"

echo "$APP_DIR"
echo "$DIST_ZIP"
