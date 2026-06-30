#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/compare-cotyping.sh cotabby|cotypist|lokalbot [output-dir]

Opens TextEdit, types the shared cotyping prompts, waits for the active
cotyping app to show a suggestion, saves one screenshot per prompt, and
records TextEdit document text before optional acceptance.
Requires Accessibility for the shell running this script and Screen Recording
for screencapture.

Set COTYPING_COMPARE_ACCEPT=1 to press Tab after the screenshot and record
the resulting TextEdit document text in *.accepted.txt.

Set COTYPING_COMPARE_INPUT_MODE=direct to avoid System Events keystrokes and
write TextEdit's document text directly. This lower-fidelity mode can show
whether suggestions appear on accessibility value changes, but it cannot verify
Tab acceptance.
USAGE
}

target="${1:-}"
case "$target" in
  cotabby) target_app="Cotabby"; target_bundle="com.jacobfu.tabby" ;;
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
accept_suggestions="${COTYPING_COMPARE_ACCEPT:-0}"
accept_wait_seconds="${COTYPING_COMPARE_ACCEPT_WAIT_SECONDS:-0.7}"
input_mode="${COTYPING_COMPARE_INPUT_MODE:-keys}"

quit_other_cotyping_apps() {
  case "$target" in
    cotabby)
      pkill -x Cotypist 2>/dev/null || true
      pkill -x LokalBot 2>/dev/null || true
      ;;
    cotypist)
      pkill -x Cotabby 2>/dev/null || true
      pkill -x LokalBot 2>/dev/null || true
      ;;
    lokalbot)
      pkill -x Cotabby 2>/dev/null || true
      pkill -x Cotypist 2>/dev/null || true
      ;;
  esac
  sleep 0.8
}

quit_other_cotyping_apps
open -b "$target_bundle" >/dev/null 2>&1 || open -a "$target_app" >/dev/null 2>&1 || true
open -b com.apple.TextEdit >/dev/null 2>&1 \
  || open /System/Applications/TextEdit.app >/dev/null 2>&1 \
  || open -a TextEdit
sleep 1

read_document_text() {
  osascript <<'OSA'
tell application "TextEdit"
  if not (exists document 1) then return ""
  return text of front document
end tell
OSA
}

capture_prompt() {
  local slug="$1"
  local prompt="$2"

  local rect
  if [[ "$input_mode" == "direct" ]]; then
    rect="$(osascript <<'OSA'
tell application "TextEdit"
  activate
  set windowBounds to bounds of front window
  set windowLeft to item 1 of windowBounds
  set windowTop to item 2 of windowBounds
  set windowRight to item 3 of windowBounds
  set windowBottom to item 4 of windowBounds
  return (windowLeft as integer as text) & "," & (windowTop as integer as text) & "," & ((windowRight - windowLeft) as integer as text) & "," & ((windowBottom - windowTop) as integer as text)
end tell
OSA
)"
  else
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
  fi
  if ! [[ "$rect" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
    printf 'Invalid TextEdit capture rect for %s: %q\n' "$slug" "$rect" >&2
    return 1
  fi
  printf '%s\n' "$rect" > "$out_dir/${slug}.rect"
  screencapture -x -R "$rect" "$out_dir/${slug}.png"
  printf '%s\n' "$prompt" > "$out_dir/${slug}.txt"
}

accept_current_suggestion() {
  osascript - "$accept_wait_seconds" <<'OSA'
on run argv
  set acceptDelay to item 1 of argv as real
  tell application "TextEdit" to activate
  delay 0.1
  tell application "System Events"
    tell process "TextEdit"
      set frontmost to true
      keystroke tab
    end tell
  end tell
  delay acceptDelay
end run
OSA
}

run_prompt() {
  local slug="$1"
  local prompt="$2"
  local wait_seconds="${3:-3}"

  if [[ "$input_mode" == "direct" ]]; then
    osascript \
      -e 'on run argv' \
      -e 'set promptText to item 1 of argv' \
      -e 'tell application "TextEdit" to activate' \
      -e 'tell application "TextEdit" to make new document' \
      -e 'tell application "TextEdit" to set text of front document to promptText' \
      -e 'end run' \
      "$prompt"
  else
    osascript - "$prompt" "$key_delay_seconds" <<'OSA'
on run argv
  set promptText to item 1 of argv
  set keyDelay to item 2 of argv as real
  tell application "TextEdit"
    activate
    make new document
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
  fi

  sleep "$wait_seconds"
  capture_prompt "$slug" "$prompt"
  read_document_text > "$out_dir/${slug}.document.txt"
  if [[ "$accept_suggestions" == "1" && "$input_mode" == "direct" ]]; then
    printf 'Skipping Tab accept for %s: direct mode does not send keystrokes.\n' "$slug" >&2
  elif [[ "$accept_suggestions" == "1" ]]; then
    accept_current_suggestion
    read_document_text > "$out_dir/${slug}.accepted.txt"
  fi
}

run_prompt "01-follow-up" "I wanted to follow" "$first_wait_seconds"
run_prompt "02-take-ownership" "I can take" "$wait_seconds"
run_prompt "03-tradeoff" "The main tradeoff is" "$wait_seconds"
run_prompt "04-when-ready" "Please receive the files when" "$wait_seconds"

cat > "$out_dir/README.md" <<EOF
# Cotyping Comparison

Target: ${target_app}
Captured: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Input mode: ${input_mode}

Review each PNG for:
- first visible suggestion latency,
- grammar and relevance,
- placeholder/bracket/question leakage,
- inline-vs-popup placement,
- spacing after accepting by word or phrase.

Each prompt also writes:
- \`*.document.txt\`: TextEdit text after waiting for the suggestion.
- \`*.accepted.txt\`: TextEdit text after one Tab accept, when
  \`COTYPING_COMPARE_ACCEPT=1\` and input mode is \`keys\`.

Read back the text files before drawing conclusions: a UI probe can fail by
partially accepting, inserting a literal Tab, or showing no visible suggestion.
EOF

echo "$out_dir"
