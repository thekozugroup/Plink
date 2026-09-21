#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${PLINK_MACOS_APP_DIR:-$ROOT_DIR/build/PlinkMac.app}"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
DIST_DIR="$ROOT_DIR/build"
DIST_ZIP="$DIST_DIR/PlinkMac.app.zip"

cd "$ROOT_DIR/macos"
swift build -c release

case "$APP_DIR" in
  */PlinkMac.app) ;;
  *) echo "PLINK_MACOS_APP_DIR must end with /PlinkMac.app" >&2; exit 1 ;;
esac
rm -rf "$APP_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/macos/.build/release/PlinkMac" "$MACOS_DIR/PlinkMac"
cp "$ROOT_DIR/macos/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/macos/Resources/Plink.icns" "$RESOURCES_DIR/Plink.icns"
cp "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" "$RESOURCES_DIR/PlinkMac.entitlements"
chmod +x "$MACOS_DIR/PlinkMac"

# Compile the existing artwork into a modern catalog; keep the ICNS fallback.
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plink-assets.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICON_CATALOG="$ICON_WORK_DIR/Plink.xcassets"
mkdir -p "$ICON_CATALOG/AppIcon.appiconset"
iconutil -c iconset "$RESOURCES_DIR/Plink.icns" -o "$ICON_WORK_DIR/Plink.iconset"
cp "$ICON_WORK_DIR/Plink.iconset/"*.png "$ICON_CATALOG/AppIcon.appiconset/"
cat > "$ICON_CATALOG/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images": [
    {"idiom":"mac", "size":"16x16", "scale":"1x", "filename":"icon_16x16.png"},
    {"idiom":"mac", "size":"16x16", "scale":"2x", "filename":"icon_16x16@2x.png"},
    {"idiom":"mac", "size":"32x32", "scale":"1x", "filename":"icon_32x32.png"},
    {"idiom":"mac", "size":"32x32", "scale":"2x", "filename":"icon_32x32@2x.png"},
    {"idiom":"mac", "size":"128x128", "scale":"1x", "filename":"icon_128x128.png"},
    {"idiom":"mac", "size":"128x128", "scale":"2x", "filename":"icon_128x128@2x.png"},
    {"idiom":"mac", "size":"256x256", "scale":"1x", "filename":"icon_256x256.png"},
    {"idiom":"mac", "size":"256x256", "scale":"2x", "filename":"icon_256x256@2x.png"},
    {"idiom":"mac", "size":"512x512", "scale":"1x", "filename":"icon_512x512.png"},
    {"idiom":"mac", "size":"512x512", "scale":"2x", "filename":"icon_512x512@2x.png"}
  ],
  "info": {"author":"xcode", "version":1}
}
JSON
printf '%s\n' '{"info":{"author":"xcode","version":1}}' > "$ICON_CATALOG/Contents.json"
xcrun actool "$ICON_CATALOG" --compile "$RESOURCES_DIR" --platform macosx \
  --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$APP_DIR/Contents/Info.plist")" \
  --app-icon AppIcon --output-partial-info-plist "$ICON_WORK_DIR/asset-info.plist"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
test -x "$MACOS_DIR/PlinkMac"
test -f "$RESOURCES_DIR/PlinkMac.entitlements"
test -f "$RESOURCES_DIR/Plink.icns"
test -f "$RESOURCES_DIR/Assets.car"

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
