#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${PLINK_MACOS_APP_DIR:-$ROOT_DIR/build/PlinkMac.app}"
DIST_DIR="$ROOT_DIR/build"
DIST_ZIP="$DIST_DIR/PlinkMac.app.zip"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT_DIR/macos"
swift build -c release

case "$APP_DIR" in
  */PlinkMac.app) ;;
  *) echo "PLINK_MACOS_APP_DIR must end with /PlinkMac.app" >&2; exit 1 ;;
esac
mkdir -p "$DIST_DIR"
mkdir -p "$(dirname "$APP_DIR")"
APP_DIR="$(cd "$(dirname "$APP_DIR")" && pwd -P)/PlinkMac.app"
case "$APP_DIR" in
  /Applications/*|"$HOME/Applications/"*) echo "Package into a build directory, not Applications" >&2; exit 1 ;;
esac
if [ -L "$APP_DIR" ]; then echo "Package output must not be a symlink" >&2; exit 1; fi

# Keep incomplete bundles out of a recognizable .app path. Staging shares the
# destination filesystem so publishing the verified bundle is a rename.
PACKAGE_WORK_DIR="$(mktemp -d "$(dirname "$APP_DIR")/.plink-package.XXXXXX")"
ZIP_WORK_FILE=""
PUBLISHED=false
cleanup() {
  local status=$?
  # The zip staging file shares DIST_ZIP's filesystem. Its rename consumes it,
  # even if a signal arrives before mv returns to the shell. Once consumed,
  # keep the verified new app+zip pair rather than rolling back only the app.
  local committed=false
  if [ "$PUBLISHED" = true ] && [ -n "$ZIP_WORK_FILE" ] && [ ! -e "$ZIP_WORK_FILE" ]; then
    committed=true
  fi
  if [ "$status" -ne 0 ] && [ "$committed" = false ]; then
    if [ "$PUBLISHED" = true ]; then rm -rf "$APP_DIR"; fi
    if [ -e "$PACKAGE_WORK_DIR/previous.app" ]; then
      if ! mv "$PACKAGE_WORK_DIR/previous.app" "$APP_DIR"; then
        echo "Could not restore previous package; retained at $PACKAGE_WORK_DIR/previous.app" >&2
        [ -z "$ZIP_WORK_FILE" ] || rm -f "$ZIP_WORK_FILE"
        exit "$status"
      fi
    fi
  fi
  rm -rf "$PACKAGE_WORK_DIR"
  [ -z "$ZIP_WORK_FILE" ] || rm -f "$ZIP_WORK_FILE"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
BUNDLE_DIR="$PACKAGE_WORK_DIR/bundle"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"
RESOURCES_DIR="$BUNDLE_DIR/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/macos/.build/release/PlinkMac" "$MACOS_DIR/PlinkMac"
cp "$ROOT_DIR/macos/Resources/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
cp "$ROOT_DIR/macos/Resources/Plink.icns" "$RESOURCES_DIR/Plink.icns"
cp "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" "$RESOURCES_DIR/PlinkMac.entitlements"
chmod +x "$MACOS_DIR/PlinkMac"

# Compile the existing artwork into a modern catalog; keep the ICNS fallback.
ICON_WORK_DIR="$PACKAGE_WORK_DIR/icons"
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
  --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$BUNDLE_DIR/Contents/Info.plist")" \
  --app-icon AppIcon --output-partial-info-plist "$ICON_WORK_DIR/asset-info.plist"

# Honor the compiler's icon declarations without replacing unrelated app metadata.
cp "$ICON_WORK_DIR/asset-info.plist" "$DIST_DIR/PlinkMac.asset-info.plist"
/usr/bin/python3 - "$ICON_WORK_DIR/asset-info.plist" "$BUNDLE_DIR/Contents/Info.plist" "$RESOURCES_DIR" <<'PY'
import json, pathlib, plistlib, sys
partial_path, info_path, resources = map(pathlib.Path, sys.argv[1:])
partial = plistlib.loads(partial_path.read_bytes())
info = plistlib.loads(info_path.read_bytes())
icon_keys = {"CFBundleIconName", "CFBundleIconFile", "CFBundleIconFiles", "CFBundleIcons"}
icons = {key: value for key, value in partial.items() if key in icon_keys}
if not icons:
    raise ValueError("actool emitted no icon declarations")
delta = {key: {"before": info.get(key), "after": value}
         for key, value in icons.items() if info.get(key) != value}
info.update(icons)
icon_file = info.get("CFBundleIconFile")
if icon_file:
    filename = icon_file if pathlib.Path(icon_file).suffix else icon_file + ".icns"
    if not (resources / filename).is_file():
        raise ValueError("Compiled icon file is missing")
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
print(json.dumps({"actool_icon_metadata": icons, "icon_metadata_delta": delta}, sort_keys=True))
PY

plutil -lint "$BUNDLE_DIR/Contents/Info.plist" >/dev/null
test -x "$MACOS_DIR/PlinkMac"
test -f "$RESOURCES_DIR/PlinkMac.entitlements"
test -f "$RESOURCES_DIR/Plink.icns"
test -f "$RESOURCES_DIR/Assets.car"

# Finder/provenance xattrs can be attached by local filesystem tools and make
# strict codesign verification fail even when the signature itself is valid.
find "$BUNDLE_DIR" -exec xattr -c {} + 2>/dev/null || true

SIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/macos/Resources/PlinkMac.entitlements" \
  "$BUNDLE_DIR"
codesign --verify --deep --strict "$BUNDLE_DIR"
codesign -d --entitlements :- "$BUNDLE_DIR" >/dev/null 2>&1

# Only the complete, verified bundle gains its final basename, including in zip.
mv "$BUNDLE_DIR" "$PACKAGE_WORK_DIR/PlinkMac.app"
ZIP_WORK_FILE="$(mktemp "$DIST_DIR/.plink-package-zip.XXXXXX")"
ditto -c -k --norsrc --noextattr --keepParent "$PACKAGE_WORK_DIR/PlinkMac.app" "$ZIP_WORK_FILE"

# Replacement is not atomic as a pair. Retain the previous app for rollback if
# publication fails; the existing zip is untouched until its replacement is ready.
if [ -e "$APP_DIR" ]; then mv "$APP_DIR" "$PACKAGE_WORK_DIR/previous.app"; fi
PUBLISHED=true
mv "$PACKAGE_WORK_DIR/PlinkMac.app" "$APP_DIR"
mv -f "$ZIP_WORK_FILE" "$DIST_ZIP"

echo "$APP_DIR"
echo "$DIST_ZIP"
