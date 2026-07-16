#!/bin/bash
# LokalBot unit-test runner. Unlike XCUITest, this does not synthesize input or
# take control of the foreground app. Keeping the invocation behind one stable
# project-local command also lets automation grant a narrow reusable approval.
#
# Usage:
#   Scripts/unit-tests.sh
#   Scripts/unit-tests.sh AppSettingsTests
#   Scripts/unit-tests.sh AppSettingsTests/testDefaults
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/LokalBot.xcodeproj"
DERIVED="$ROOT/.build/XcodeDerivedData"

ARGS=(
  -quiet
  -project "$PROJECT"
  -scheme LokalBot
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
  -skip-testing:LokalBotUITests
)

if [ "${1:-}" != "" ]; then
  FILTER="${1#LokalBotTests/}"
  ARGS+=(-only-testing:"LokalBotTests/$FILTER")
fi

xcodebuild "${ARGS[@]}" test
