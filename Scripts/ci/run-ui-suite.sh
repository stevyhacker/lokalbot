#!/bin/bash
# Hosted-only phases share the same selection so early tests are not repeated.
set -euo pipefail
cd "$(dirname "$0")/../.."

SMOKE=(
  RedesignUITests/testHighContrastKeepsActionsAccessible
  MainWindowUITests/testMeetingWaveformExposesSliderAndSupportsKeyboardSeeking
  AgentModeUITests
  RedesignUITests/testAgentApprovalDescribesEffectAndDenialAndStopReachTheController
  RedesignUITests/testFourHundredActionsStaySearchableAndCompletionCanBeUndone
  MainWindowUITests/testMultiMeetingThreadCompletionRequiresConfirmation
  MainWindowUITests/testActionThreadSourceCanBeSeparatedAndRestored
)
REDUCED=RedesignUITests/testReducedMotionWorkspaceRemainsOperable
PHASE="${1:?Specify smoke, reduced-motion, remainder, or single}"
ARGS=(--test-only --result ".build/ui-results/$PHASE.xcresult")
case "$PHASE" in
  smoke)
    for test in "${SMOKE[@]}"; do ARGS+=(--only "$test"); done
    ;;
  reduced-motion)
    ARGS+=(--only "$REDUCED")
    ;;
  remainder)
    for test in "${SMOKE[@]}"; do ARGS+=(--skip "$test"); done
    # This test is covered by the dedicated enabled Reduce Motion phase.
    ARGS+=(--skip "$REDUCED")
    ;;
  single)
    ARGS+=(--only "${2:?Specify the requested test filter}")
    ;;
  *) echo "Unknown UI phase: $PHASE" >&2; exit 2 ;;
esac
mkdir -p .build/ui-results
started=$SECONDS
result=0
Scripts/ui-tests.sh "${ARGS[@]}" 2>&1 | tee ".build/ui-results/$PHASE.log" || result=$?
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '| %s | %ss | exit %s |\n' "$PHASE" "$((SECONDS - started))" "$result" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$result"
