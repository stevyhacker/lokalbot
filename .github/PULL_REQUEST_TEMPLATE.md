## Summary

<!--
One or two sentences: what changed and why. Skip the play-by-play.
The diff already shows what; this section should explain why.
-->

## Validation

<!--
What you actually ran and what you actually saw, not what you intended to run.
Examples:

  xcodegen generate
  xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  # ** TEST SUCCEEDED **  N tests, 0 failures

  swiftlint lint --strict --quiet
  # exit 0

For UI changes, attach a screenshot or short screen recording.
For changes that can't be verified end-to-end yet, say so explicitly.
-->

## Linked issues

<!--
Use `Fixes #N` to auto-close on merge, `Refs #N` to link without closing.
-->

## Risk / rollout notes

<!--
Anything reviewers should know that isn't visible from the diff:
- project.yml, settings, or schema migrations
- Behavior changes that touch existing recording / transcription / summary flows
- Permission (TCC) or signing / notarization implications
- Performance characteristics worth flagging

Skip this section entirely if there's nothing to flag.
-->
