#!/bin/bash
# LokalBot UI test runner: remote by default, foreground only by opt-in.
#
# Drives the dedicated LokalBot UI Test Host via XCUITest against a
# synthetic meetings library — no microphone/screen-recording permissions,
# no real audio, no network. The host is compiled with LOKALBOT_UI_TEST=1
# and skips every side-effectful subsystem (Core Audio polling,
# accessibility-trusted detector, Sparkle, screenshots).
#
# Local XCUITest sends real mouse and keyboard events. It therefore owns the
# foreground while it runs; it cannot be made invisible in the same login
# session without weakening these into non-UI tests. Prefer --remote, which
# dispatches the existing GitHub Actions job and returns immediately.
#
# Prereq for explicit --foreground runs (macOS TCC): the controlling terminal
# and generated test runner MUST hold:
#   • Privacy & Security → Automation → Xcode  (allowed)
#   • Privacy & Security → Accessibility       (allowed)
# without these, the XCUITest runner fails with
# "Timed out while enabling automation mode." — that error is the missing
# TCC grant, NOT a bug in the suite. The UI-test target is development-signed
# with a stable bundle identity so the grant survives ordinary rebuilds.
#
# Usage:
#   Scripts/ui-tests.sh                # dispatch all tests without stealing focus
#   Scripts/ui-tests.sh --remote       # explicit form of the default above
#   Scripts/ui-tests.sh --remote MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
#   Scripts/ui-tests.sh --build-only   # compile without launching the app
#   Scripts/ui-tests.sh --foreground   # run all tests in this login session
#   Scripts/ui-tests.sh --foreground MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/LokalBot.xcodeproj"
DERIVED=".build/dd"
SCHEME="LokalBot UI Test Host"

MODE=""
FILTER=""

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" \
    | sed '$d; s/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="remote"
      ;;
    --build-only)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="build"
      ;;
    --foreground)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="foreground"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$FILTER" ]; then
        echo "Only one test filter may be supplied." >&2
        exit 2
      fi
      FILTER="$1"
      ;;
  esac
  shift
done

# A developer invocation is remote by default. CI keeps running the suite on
# its hosted macOS session, where foreground ownership cannot disturb anyone.
if [ -z "$MODE" ] && [ -z "${CI:-}" ]; then
  MODE="remote"
fi

if [ "$MODE" = "remote" ]; then
  command -v gh >/dev/null 2>&1 || {
    echo "GitHub CLI (gh) is required for --remote." >&2
    exit 2
  }

  BRANCH="$(git -C "$(dirname "$PROJECT")" branch --show-current)"
  if [ -z "$BRANCH" ]; then
    echo "--remote requires a named branch." >&2
    exit 2
  fi

  # A remote runner cannot see working-tree changes. Refuse to report a green
  # result for stale UI code while still allowing unrelated local work.
  UI_PATHS=(
    LokalBot
    LokalBotUITests
    project.yml
    Scripts/ui-tests.sh
    .github/workflows/ui-tests.yml
  )
  if ! git -C "$(dirname "$PROJECT")" diff --quiet HEAD -- "${UI_PATHS[@]}" \
      || [ -n "$(git -C "$(dirname "$PROJECT")" ls-files --others --exclude-standard -- "${UI_PATHS[@]}")" ]; then
    echo "Remote UI tests would not include the current UI/test changes." >&2
    echo "Commit and push those paths first, then rerun --remote." >&2
    exit 2
  fi

  UPSTREAM="$(git -C "$(dirname "$PROJECT")" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [ -z "$UPSTREAM" ] \
      || [ "$(git -C "$(dirname "$PROJECT")" rev-parse HEAD)" != "$(git -C "$(dirname "$PROJECT")" rev-parse "$UPSTREAM")" ]; then
    echo "--remote requires the current HEAD to be pushed to its upstream branch." >&2
    exit 2
  fi

  exec gh workflow run ui-tests.yml --ref "$BRANCH" --raw-field "filter=$FILTER"
fi

ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
)

# CI runners hold no signing certificate; let workflows opt out of signing
# (CODE_SIGNING_ALLOWED=NO Scripts/ui-tests.sh) without changing local runs.
if [ "${CODE_SIGNING_ALLOWED:-}" != "" ]; then
  ARGS+=("CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED}")
fi

if [ -n "$FILTER" ]; then
  FILTER="${FILTER#LokalBotUITests/}"
  ARGS+=(-only-testing:"LokalBotUITests/$FILTER")
else
  ARGS+=(-only-testing:LokalBotUITests)
fi

echo "→ building for testing…"
xcodebuild "${ARGS[@]}" build-for-testing | tail -3

if [ "$MODE" = "build" ]; then
  exit 0
fi

echo "→ running UI tests…"
xcodebuild "${ARGS[@]}" test-without-building
