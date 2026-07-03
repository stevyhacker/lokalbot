#!/bin/bash
# LokalBot UI test runner.
#
# Drives the dedicated LokalBot UI Test Host via XCUITest against a
# synthetic meetings library — no microphone/screen-recording permissions,
# no real audio, no network. The host is compiled with LOKALBOT_UI_TEST=1
# and skips every side-effectful subsystem (Core Audio polling,
# accessibility-trusted detector, Sparkle, screenshots).
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
#   Scripts/ui-tests.sh MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/LokalBot.xcodeproj"
DERIVED=".build/dd"
SCHEME="LokalBot UI Test Host"

ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
)

# CI runners hold no signing certificate; let workflows opt out of signing
# (CODE_SIGNING_ALLOWED=NO Scripts/ui-tests.sh) without changing local runs.
if [ "${CODE_SIGNING_ALLOWED:-}" != "" ]; then
  ARGS+=("CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED}")
fi

if [ "${1:-}" != "" ]; then
  FILTER="${1#LokalBotUITests/}"
  ARGS+=(-only-testing:"LokalBotUITests/$FILTER")
else
  ARGS+=(-only-testing:LokalBotUITests)
fi

echo "→ building for testing…"
xcodebuild "${ARGS[@]}" build-for-testing | tail -3

echo "→ running UI tests…"
xcodebuild "${ARGS[@]}" test-without-building
