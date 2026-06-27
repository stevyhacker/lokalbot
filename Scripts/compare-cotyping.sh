#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/compare-cotyping.sh cotypist|lokalbot [output-dir]

Opens TextEdit, types the shared cotyping prompts, waits for the active
cotyping app to show a suggestion, and saves one screenshot per prompt.
Requires Accessibility for the shell running this script and Screen Recording
for screencapture.
USAGE
}

target="${1:-}"
case "$target" in
  cotypist) target_app="Cotypist"; target_bundle="app.cotypist.Cotypist" ;;
  lokalbot) target_app="LokalBot"; target_bundle="me.dotenv.LokalBot" ;;
  -h|--help|"") usage; exit 64 ;;
  *) usage; exit 64 ;;
esac

out_dir="${2:-/tmp/cotyping-comparison-${target}-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out_dir"
wait_seconds="${COTYPING_COMPARE_WAIT_SECONDS:-5}"
first_wait_seconds="${COTYPING_COMPARE_FIRST_WAIT_SECONDS:-12}"
key_delay_seconds="${COTYPING_COMPARE_KEY_DELAY_SECONDS:-0.025}"

open -b "$target_bundle" >/dev/null 2>&1 || open -a "$target_app" >/dev/null 2>&1 || true
open -b com.apple.TextEdit >/dev/null 2>&1 \
  || open /System/Applications/TextEdit.app >/dev/null 2>&1 \
  || open -a TextEdit
sleep 1

capture_prompt() {
  local slug="$1"
  local prompt="$2"

  local rect
  rect="$(osascript <<'OSA'
tell application "TextEdit" to activate
delay 0.5
tell application "System Events"
  tell process "TextEdit"
    set frontmost to true
    set documentWindow to missing value
    set largestArea to 0
    repeat with candidateWindow in windows
      set candidateSize to value of attribute "AXSize" of candidateWindow
      set candidateArea to (item 1 of candidateSize) * (item 2 of candidateSize)
      set candidateSubrole to ""
      try
        set candidateSubrole to value of attribute "AXSubrole" of candidateWindow
      end try
      if candidateSubrole is "AXStandardWindow" and candidateArea > largestArea then
        set documentWindow to candidateWindow
        set largestArea to candidateArea
      end if
    end repeat
    if documentWindow is missing value then set documentWindow to window 1
    perform action "AXRaise" of documentWindow
    set windowPosition to value of attribute "AXPosition" of documentWindow
    set windowSize to value of attribute "AXSize" of documentWindow
    return ((item 1 of windowPosition as integer) as text) & "," & ((item 2 of windowPosition as integer) as text) & "," & ((item 1 of windowSize as integer) as text) & "," & ((item 2 of windowSize as integer) as text)
  end tell
end tell
OSA
)"
  if ! [[ "$rect" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
    printf 'Invalid TextEdit capture rect for %s: %q\n' "$slug" "$rect" >&2
    return 1
  fi
  printf '%s\n' "$rect" > "$out_dir/${slug}.rect"
  screencapture -x -R "$rect" "$out_dir/${slug}.png"
  printf '%s\n' "$prompt" > "$out_dir/${slug}.txt"
}

run_prompt() {
  local slug="$1"
  local prompt="$2"
  local wait_seconds="${3:-3}"

  osascript - "$prompt" "$key_delay_seconds" <<'OSA'
on run argv
  set promptText to item 1 of argv
  set keyDelay to item 2 of argv as real
  tell application "TextEdit"
    activate
    if not (exists document 1) then make new document
    set text of front document to ""
  end tell
  delay 0.3
  tell application "System Events"
    tell process "TextEdit"
      set frontmost to true
      perform action "AXRaise" of window 1
      repeat with characterIndex from 1 to count characters of promptText
        keystroke (character characterIndex of promptText)
        if keyDelay > 0 then delay keyDelay
      end repeat
    end tell
  end tell
end run
OSA

  sleep "$wait_seconds"
  capture_prompt "$slug" "$prompt"
}

run_prompt "01-follow-up" "I wanted to follow" "$first_wait_seconds"
run_prompt "02-take-ownership" "I can take" "$wait_seconds"
run_prompt "03-tradeoff" "The main tradeoff is" "$wait_seconds"
run_prompt "04-when-ready" "Please receive the files when" "$wait_seconds"

cat > "$out_dir/README.md" <<EOF
# Cotyping Comparison

Target: ${target_app}
Captured: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Review each PNG for:
- first visible suggestion latency,
- grammar and relevance,
- placeholder/bracket/question leakage,
- inline-vs-popup placement,
- spacing after accepting by word or phrase.
EOF

echo "$out_dir"
