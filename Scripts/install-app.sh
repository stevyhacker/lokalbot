#!/bin/bash
# Builds BotinaV2 and installs it to /Applications, then relaunches it.
# Keeping one canonical copy at a human-findable path ends the
# "which BotinaV2.app do I grant permissions to?" problem.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Debug \
  -allowProvisioningUpdates build 2>&1 | grep -E "^\*\*|error:" | head -5

APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/LokalBot-*/Build/Products/Debug/BotinaV2.app | head -1)
pkill -x BotinaV2 2>/dev/null || true
sleep 1
rm -rf /Applications/BotinaV2.app
ditto "$APP" /Applications/BotinaV2.app   # ditto preserves signature + metadata
open -n /Applications/BotinaV2.app
echo "installed + launched /Applications/BotinaV2.app"
