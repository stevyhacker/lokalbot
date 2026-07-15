#!/bin/bash
#
# Regenerate the README screenshots and GIFs from the real app UI.
#
# Builds the UI-test host, seeds a synthetic meeting library, then lands the
# host on each section via the LOKALBOT_* capture env vars (handled in the app
# only under the LOKALBOT_UI_TEST_HOST build flag). The host renders its own
# window to a 2x PNG in-process (LOKALBOT_CAPTURE_FILE) and quits -- so a
# running production LokalBot is never touched and no TCC grant is needed.
#
# Produces in Assets/screenshots/:
#   *.png      one still per section
#   hero.gif   a tour across sections
#   recap.gif  browsing meeting recaps + transcript
#   search.gif searching across meetings
#
# Requires: Xcode, a configured signing team, ffmpeg (for the GIFs).
#
set -euo pipefail
cd "$(dirname "$0")/.."
# Detach stdin: backgrounded GUI children must not inherit (and consume) the
# shell's stdin, which can otherwise garble the rest of this script.
exec </dev/null

SCHEME="LokalBot UI Test Host"
OUT="$PWD/Assets/screenshots"
FRAMES="$(mktemp -d)"          # GIF-only frames (kept out of Assets/)
LIB="${TMPDIR:-/tmp}/lokalbot-demo-lib"
SUITE="lokalbot.shots.$(uuidgen)"
mkdir -p "$OUT"

echo "==> Building '$SCHEME'"
xcodebuild -project LokalBot.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'platform=macOS' build >/dev/null
PRODUCTS=$(xcodebuild -project LokalBot.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS/LokalBot UI Test Host.app/Contents/MacOS/LokalBot UI Test Host"

echo "==> Seeding demo library"
python3 Scripts/seed_demo_library.py "$LIB"

# capture <dest-dir> <name> [ENV=val ...]
capture() {
  dest="$1"; name="$2"; shift 2
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  sleep 1
  rm -f "$dest/$name.png"
  env LOKALBOT_UI_TEST=1 LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE" \
      LOKALBOT_CAPTURE_FILE="$dest/$name.png" LOKALBOT_CAPTURE_SIZE=1320x820 "$@" \
    "$APP" -ApplePersistenceIgnoreState YES -AppleLocale en_US -AppleLanguages "(en)" \
    --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" \
    </dev/null >/dev/null 2>&1 &
  for _ in $(seq 1 40); do
    [ -s "$dest/$name.png" ] && break
    sleep 0.5
  done
  sleep 0.3   # let the PNG write finish before the next launch recycles the app
  if [ -s "$dest/$name.png" ]; then
    echo "    $name.png"
  else
    echo "    !! capture failed for $name"
  fi
}

echo "==> Capturing section stills"
capture "$OUT" meetings-summary    LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary    LOKALBOT_DISMISS_ONBOARDING=1
capture "$OUT" meetings-transcript LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=transcript LOKALBOT_DISMISS_ONBOARDING=1
capture "$OUT" timeline            LOKALBOT_INITIAL_SECTION=timeline LOKALBOT_DISMISS_ONBOARDING=1
capture "$OUT" search              LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=Redis
capture "$OUT" models              LOKALBOT_INITIAL_SECTION=models
capture "$OUT" cotyping            LOKALBOT_INITIAL_SECTION=cotyping LOKALBOT_COTYPING_DEMO=1
capture "$OUT" settings            LOKALBOT_INITIAL_SECTION=settings
capture "$OUT" chat                LOKALBOT_INITIAL_SECTION=chat LOKALBOT_DISMISS_ONBOARDING=1

echo "==> Capturing GIF sequence frames"
capture "$FRAMES" recap-northwind  LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=3 LOKALBOT_DETAIL_TAB=summary LOKALBOT_DISMISS_ONBOARDING=1
capture "$FRAMES" recap-q3         LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=2 LOKALBOT_DETAIL_TAB=summary LOKALBOT_DISMISS_ONBOARDING=1
capture "$FRAMES" search-sso       LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=SSO
capture "$FRAMES" search-postgres  LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=Postgres
pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "==> ffmpeg not found; PNGs written, skipping GIFs"
  exit 0
fi

echo "==> Assembling GIFs"
# Widths are 2x the README display size (880/860); assemble_gif never upscales,
# so 1x captures pass through at native size.
python3 Scripts/assemble_gif.py "$OUT/hero.gif" 1760 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$OUT/search.png" "$OUT/chat.png" "$OUT/timeline.png" "$OUT/cotyping.png"
python3 Scripts/assemble_gif.py "$OUT/recap.gif" 1720 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$FRAMES/recap-northwind.png" "$FRAMES/recap-q3.png"
python3 Scripts/assemble_gif.py "$OUT/search.gif" 1720 \
  "$OUT/search.png" "$FRAMES/search-sso.png" "$FRAMES/search-postgres.png"

echo "==> Assembling landing-page hero video"
# 1872 = 2x the landing page's 936px display slot.
python3 Scripts/assemble_gif.py "web/assets/hero-demo.mp4" 1872 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$OUT/search.png" "$OUT/chat.png" "$OUT/timeline.png" "$OUT/cotyping.png"
ffmpeg -y -v error -i "web/assets/hero-demo.mp4" -frames:v 1 -q:v 3 "web/assets/hero-poster.jpg"
echo "    web/assets/hero-poster.jpg"

echo "==> Done: $OUT/{*.png, hero.gif, recap.gif, search.gif} + web/assets/hero-demo.mp4"
