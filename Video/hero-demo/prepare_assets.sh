#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)
ASSET_DIR="$PROJECT_DIR/assets"

mkdir -p "$ASSET_DIR"

for name in meetings-summary meetings-transcript search chat timeline quick-recall dictation cotyping; do
  cp "$REPO_ROOT/Assets/screenshots/$name.png" "$ASSET_DIR/$name.png"
done
cp "$REPO_ROOT/Assets/lokalbot-icon.svg" "$ASSET_DIR/lokalbot-icon.svg"

"$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/generate_audio.py"
"$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/write_captions.py"
