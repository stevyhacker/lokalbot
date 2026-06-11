#!/bin/bash
# Builds LokalBot and installs it to /Applications, then relaunches it.
# Keeping one canonical copy at a human-findable path ends the
# "which LokalBot.app do I grant permissions to?" problem.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Debug \
  -allowProvisioningUpdates build 2>&1 | grep -E "^\*\*|error:" | head -5

APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/LokalBot-*/Build/Products/Debug/LokalBot.app | head -1)
pkill -x LokalBot 2>/dev/null || true
sleep 1
rm -rf /Applications/LokalBot.app
ditto "$APP" /Applications/LokalBot.app   # ditto preserves signature + metadata
open -n /Applications/LokalBot.app
echo "installed + launched /Applications/LokalBot.app"
