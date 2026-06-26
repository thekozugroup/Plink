#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ ! -f local.properties ] && [ -d "$HOME/Library/Android/sdk" ]; then
  printf 'sdk.dir=%s/Library/Android/sdk\n' "$HOME" > local.properties
fi

./scripts/check-fixtures.sh
if grep -Eq 'READ_SMS|SEND_SMS|RECEIVE_SMS' android/src/main/AndroidManifest.xml; then
  echo "Android manifest must not request SMS permissions until default-SMS role flow is implemented." >&2
  exit 1
fi

./gradlew --no-daemon :android:clean :android:assembleDebug :android:assembleRelease :android:lintDebug :android:testDebugUnitTest
(cd macos && swift test && swift build)
./scripts/package-macos.sh

git status --short
