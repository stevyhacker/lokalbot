#!/bin/bash
#
# Regenerate the README screenshots and hero GIF from the real app UI.
#
# Builds the UI-test host, seeds a synthetic meeting library, then lands the
# host on each section via the LOKALBOTV3_* capture env vars (handled in the
# app only under the LOKALBOTV3_UI_TEST_HOST build flag) and screenshots each
# window by its own PID -- so a running production LokalBot is never touched.
# No TCC permissions beyond Screen Recording for the controlling terminal.
#
# Requires: Xcode, a configured signing team, ffmpeg (for the GIF).
# Output:   Assets/screenshots/{*.png, hero.gif}
#
set -euo pipefail
cd "$(dirname "$0")/.."
# Detach stdin: backgrounded GUI children must not inherit (and consume) the
# shell's stdin, which can otherwise garble the rest of this script.
exec </dev/null

SCHEME="LokalBot UI Test Host"
OUT="$PWD/Assets/screenshots"
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
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("\(wid)\t\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
}
SWIFT

capture() {
  name="$1"; shift
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  sleep 1
  env LOKALBOTV3_UI_TEST=1 LOKALBOTV3_STORAGE_ROOT="$LIB" LOKALBOTV3_DEFAULTS_SUITE="$SUITE" "$@" \
    "$APP" -ApplePersistenceIgnoreState YES \
    --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" \
    </dev/null >/dev/null 2>&1 &
  pid=$!
  sleep 6
  wid=$(swift "$WIN" "$pid" | sort -t"$(printf '\t')" -k2 -r | head -1 | cut -f1 || true)
  if [ -n "$wid" ]; then
    screencapture -l"$wid" -o "$OUT/$name.png"
    echo "    $name.png"
  else
    echo "    !! no window for $name (pid=$pid)"
  fi
}

echo "==> Capturing screens"
capture meetings-summary    LOKALBOTV3_INITIAL_SECTION=meetings LOKALBOTV3_SELECT_FIRST=1 LOKALBOTV3_DISMISS_ONBOARDING=1
capture meetings-transcript LOKALBOTV3_INITIAL_SECTION=meetings LOKALBOTV3_SELECT_FIRST=1 LOKALBOTV3_DETAIL_TAB=transcript LOKALBOTV3_DISMISS_ONBOARDING=1
capture timeline            LOKALBOTV3_INITIAL_SECTION=timeline LOKALBOTV3_DISMISS_ONBOARDING=1
capture search              LOKALBOTV3_INITIAL_SECTION=search LOKALBOTV3_INITIAL_SEARCH=Redis
capture models              LOKALBOTV3_INITIAL_SECTION=models
capture cotyping            LOKALBOTV3_INITIAL_SECTION=cotyping
capture settings            LOKALBOTV3_INITIAL_SECTION=settings
capture chat                LOKALBOTV3_INITIAL_SECTION=chat
pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "==> ffmpeg not found; PNGs written, skipping hero.gif"
  exit 0
fi

echo "==> Assembling hero.gif"
TMP="$(mktemp -d)"; BG=0x0e141c
ORDER=(meetings-summary meetings-transcript search timeline cotyping)
INPUTS=(); i=0
for n in "${ORDER[@]}"; do
  ffmpeg -y -i "$OUT/$n.png" -vf "pad=1260:904:40:40:color=$BG" "$TMP/n$i.png" >/dev/null 2>&1
  INPUTS+=(-loop 1 -t 2.5 -i "$TMP/n$i.png"); i=$((i + 1))
done
ffmpeg -y "${INPUTS[@]}" -filter_complex \
  "[0][1]xfade=transition=slideleft:duration=0.5:offset=2[v1];\
[v1][2]xfade=transition=slideleft:duration=0.5:offset=4[v2];\
[v2][3]xfade=transition=slideleft:duration=0.5:offset=6[v3];\
[v3][4]xfade=transition=slideleft:duration=0.5:offset=8,fps=15,format=yuv420p[out]" \
  -map "[out]" "$TMP/slideshow.mp4" >/dev/null 2>&1
ffmpeg -y -i "$TMP/slideshow.mp4" \
  -vf "fps=12,scale=1000:-1:flags=lanczos,palettegen=stats_mode=diff" "$TMP/palette.png" >/dev/null 2>&1
ffmpeg -y -i "$TMP/slideshow.mp4" -i "$TMP/palette.png" \
  -lavfi "fps=12,scale=1000:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT/hero.gif" >/dev/null 2>&1

echo "==> Done: $OUT/{*.png, hero.gif}"
