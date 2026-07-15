#!/bin/bash
#
# Regenerate the README screenshots and GIFs from the real app UI.
#
# Builds the UI-test host, seeds a synthetic meeting library, then lands the
# host on each section via the LOKALBOT_* capture env vars (handled in the app
# only under the LOKALBOT_UI_TEST_HOST build flag) and screenshots each
# window by its own PID -- so a running production LokalBot is never touched.
# No TCC permissions beyond Screen Recording for the controlling terminal.
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

WIN="$(mktemp -d)/winfind.swift"
cat > "$WIN" <<'SWIFT'
import CoreGraphics
import Foundation
let targetPID = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in infos {
    guard (w[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    if let t = targetPID, pid != t { continue }
    print(w[kCGWindowNumber as String] as? Int ?? 0)
}
SWIFT

# capture <dest-dir> <name> [ENV=val ...]
capture() {
  dest="$1"; name="$2"; shift 2
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  sleep 1
  env LOKALBOT_UI_TEST=1 LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE" "$@" \
    "$APP" -ApplePersistenceIgnoreState YES -AppleLocale en_US -AppleLanguages "(en)" \
    --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" \
    </dev/null >/dev/null 2>&1 &
  pid=$!
  sleep 6
  wid=$(swift "$WIN" "$pid" | head -1 || true)
  if [ -n "$wid" ]; then
    screencapture -l"$wid" -o "$dest/$name.png"
    echo "    $name.png"
  else
    echo "    !! no window for $name (pid=$pid)"
  fi
}

echo "==> Capturing section stills"
capture "$OUT" meetings-summary    LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary    LOKALBOT_DISMISS_ONBOARDING=1
capture "$OUT" meetings-transcript LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=transcript LOKALBOT_DISMISS_ONBOARDING=1
capture "$OUT" timeline            LOKALBOT_INITIAL_SECTION=timeline LOKALBOT_DISMISS_ONBOARDING=1
capture "$OUT" search              LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=Redis
capture "$OUT" models              LOKALBOT_INITIAL_SECTION=models
capture "$OUT" cotyping            LOKALBOT_INITIAL_SECTION=cotyping
capture "$OUT" settings            LOKALBOT_INITIAL_SECTION=settings
capture "$OUT" chat                LOKALBOT_INITIAL_SECTION=chat

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
python3 Scripts/assemble_gif.py "$OUT/hero.gif" 1000 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$OUT/search.png" "$OUT/timeline.png" "$OUT/cotyping.png"
python3 Scripts/assemble_gif.py "$OUT/recap.gif" 940 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$FRAMES/recap-northwind.png" "$FRAMES/recap-q3.png"
python3 Scripts/assemble_gif.py "$OUT/search.gif" 940 \
  "$OUT/search.png" "$FRAMES/search-sso.png" "$FRAMES/search-postgres.png"

echo "==> Done: $OUT/{*.png, hero.gif, recap.gif, search.gif}"
