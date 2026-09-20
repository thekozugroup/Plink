#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Homebrew keeps its JDK outside macOS's java_home search path.
if [ -z "${JAVA_HOME:-}" ] && [ -x /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
fi
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ ! -f local.properties ] && [ -d "$HOME/Library/Android/sdk" ]; then
  printf 'sdk.dir=%s/Library/Android/sdk\n' "$HOME" > local.properties
fi

printf 'Verification started (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Repository commit: %s\n' "$(git rev-parse HEAD)"
git status --short
sw_vers
"${JAVA_HOME:+$JAVA_HOME/bin/}java" -version
./gradlew --version
swift --version
xcodebuild -version
xcrun --sdk macosx --show-sdk-version

./scripts/check-fixtures.sh
if grep -Eq 'READ_SMS|SEND_SMS|RECEIVE_SMS' android/src/main/AndroidManifest.xml; then
  echo "Android manifest must not request SMS permissions until default-SMS role flow is implemented." >&2
  exit 1
fi

./gradlew --no-daemon :android:printBuildEnvironment :android:clean :android:assembleDebug :android:assembleRelease :android:assembleDebugAndroidTest :android:lintDebug :android:testDebugUnitTest
(cd macos && swift test && swift build)
./scripts/package-macos.sh

git status --short
