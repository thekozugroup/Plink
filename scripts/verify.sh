#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ ! -f local.properties ] && [ -d "$HOME/Library/Android/sdk" ]; then
  printf 'sdk.dir=%s/Library/Android/sdk\n' "$HOME" > local.properties
fi

./scripts/check-fixtures.sh
./gradlew --no-daemon :android:lintDebug :android:testDebugUnitTest
(cd macos && swift test && swift build)

git status --short
