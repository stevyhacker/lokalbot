#!/usr/bin/env bash
# Build a quick UNSIGNED test DMG from a local Debug build of BotinaV2, to
# rehearse the drag-to-Applications install flow. Release DMGs are notarized +
# Sparkle-signed via CI / RELEASING.md — this one is for eyeballing layout only.
# Usage: bash Scripts/build_test_dmg.sh [output.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_PATH="${1:-/tmp/BotinaV2-test.dmg}"
VENV_DIR="/tmp/BotinaV2-dmg-venv"
VENV_PY="$VENV_DIR/bin/python3"

# dmgbuild lives in an isolated venv: Homebrew Python is PEP 668-managed, so
# `pip install` against it fails with "externally-managed-environment". A
# throwaway venv sidesteps that and keeps the system interpreter clean.
if [ ! -x "$VENV_PY" ]; then
  echo "Creating dmgbuild venv at $VENV_DIR…"
  python3 -m venv "$VENV_DIR"
fi
if ! "$VENV_PY" -c "import dmgbuild" 2>/dev/null; then
  echo "Installing dmgbuild into venv…"
  "$VENV_PY" -m pip install --quiet --upgrade pip
  "$VENV_PY" -m pip install --quiet dmgbuild
fi

# Build the Debug app (same flow as Scripts/install-app.sh). The grep keeps the
# log readable; the bundle-existence check below is the real gate.
echo "Building BotinaV2 (Debug)…"
xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Debug \
  -allowProvisioningUpdates build 2>&1 | grep -E "^\*\*|error:" | head -5 || true

APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/LokalBot-*/Build/Products/Debug/BotinaV2.app 2>/dev/null | head -1 || true)
[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || { echo "BotinaV2.app not found after build"; exit 1; }

# Debug builds aren't notarized, so Gatekeeper flags a DMG-mounted copy as
# "damaged". Strip quarantine + ad-hoc sign so the test DMG launches without
# manual xattr surgery.
echo "Stripping quarantine and ad-hoc signing…"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# Eject stale BotinaV2 volumes first; a remount as "BotinaV2 1" would leave a
# blank Finder window and lock files mid-build.
while IFS= read -r vol; do
  [ -z "$vol" ] && continue
  hdiutil detach "$vol" -quiet 2>/dev/null && echo "Ejected $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -i "^BotinaV2" | sed 's|^|/Volumes/|' || true)

echo "Building test DMG…"
"$VENV_PY" Scripts/build_release_dmg.py --app "$APP_PATH" --output "$OUTPUT_PATH"

# Strip quarantine from the produced image too, so opening it doesn't prompt.
xattr -cr "$OUTPUT_PATH"

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
