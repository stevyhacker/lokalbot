#!/bin/bash
# LokalBotV3 UI test runner.
#
# Drives LokalBotV3.app headlessly via XCUITest against a synthetic meetings
# library — no microphone/screen-recording permissions, no real audio,
# no network. The app sees LOKALBOTV3_UI_TEST=1 and skips every
# side-effectful subsystem (Core Audio polling, accessibility-trusted
# detector, Sparkle, screenshots).
#
# Prereq (macOS TCC): the controlling terminal (Terminal.app, iTerm, Zed,
# CI runner agent…) MUST hold:
#   • Privacy & Security → Automation → Xcode  (allowed)
#   • Privacy & Security → Accessibility       (allowed)
# without these, the XCUITest runner fails with
# "Timed out while enabling automation mode." — that error is the missing
# TCC grant, NOT a bug in the suite. The grant only needs to happen once.
#
# Usage:
#   Scripts/ui-tests.sh                # all UI tests
#   Scripts/ui-tests.sh testSearch     # filter by method name substring
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/LokalBot.xcodeproj"
DERIVED=".build/dd"

ARGS=(
  -project "$PROJECT"
  -scheme LokalBot
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
)

if [ "${1:-}" != "" ]; then
  ARGS+=(-only-testing:"LokalBotUITests/MainWindowUITests/$1")
else
  ARGS+=(-only-testing:LokalBotUITests)
fi

echo "→ building for testing…"
xcodebuild "${ARGS[@]}" build-for-testing | tail -3

echo "→ running UI tests…"
xcodebuild "${ARGS[@]}" test-without-building
