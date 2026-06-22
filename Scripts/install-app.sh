#!/bin/bash
# Builds LokalBotV3 and installs it to /Applications, then relaunches it.
# Keeping one canonical copy at a human-findable path ends the
# "which LokalBotV3.app do I grant permissions to?" problem.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Debug \
  -allowProvisioningUpdates build 2>&1 | grep -E "^\*\*|error:" | head -5

APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/LokalBot-*/Build/Products/Debug/LokalBotV3.app | head -1)
pkill -x LokalBotV3 2>/dev/null || true
sleep 1
rm -rf /Applications/LokalBotV3.app
ditto "$APP" /Applications/LokalBotV3.app   # ditto preserves signature + metadata
open -n /Applications/LokalBotV3.app
echo "installed + launched /Applications/LokalBotV3.app"
