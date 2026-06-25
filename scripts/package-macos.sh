#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/PlinkMac.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT_DIR/macos"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/macos/.build/release/PlinkMac" "$MACOS_DIR/PlinkMac"
cp "$ROOT_DIR/macos/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" "$RESOURCES_DIR/PlinkMac.entitlements"
chmod +x "$MACOS_DIR/PlinkMac"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
test -x "$MACOS_DIR/PlinkMac"
test -f "$RESOURCES_DIR/PlinkMac.entitlements"

SIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" \
  "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
codesign -d --entitlements :- "$APP_DIR" >/dev/null 2>&1

echo "$APP_DIR"
