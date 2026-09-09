# Speaker capture, microphone matching, and outcome ownership

9 September 2026. Follow-up to the speaker identification and attribution changes.

## Changes

- A recording-bound Google Meet window can be observed while another application is foreground. Chrome must still have the verified meeting selected in that window. An unbound background window, a different meeting, an excluded/private source, a minimized window, a locked screen, or a source change cannot supply evidence. Frames stop on source loss or when visual identification is disabled.
- The Accessibility reader requests Chromium's web accessibility tree, fetches node attributes in batches, and distinguishes permission, timeout, traversal-budget, and source errors. It accepts participant-labelled containers and matching participant-name/control pairs, ignores embedded documents, and deduplicates nested tile containers without merging distinct people. Revalidation checks identity and layout separately from changing speaking indicators. Paired/shared-room tiles remain ambiguous.
- Observation counters and fixed failure codes are checkpointed even when no activity interval is captured. The encrypted session retains the diagnostics, and a content-free final count appears in the debug log. Names, URLs, screenshots, and voice vectors are absent from these logs. Storage read failures remain I/O failures instead of being reported as corrupt ciphertext.
- Echo removal is no longer a blanket prerequisite for microphone voice material. Clear, separated microphone samples may also qualify when both recorder clocks map the entire padded window and the actual system waveform is quiet. Remote speech, short sound bursts, missing/truncated reference data, clock gaps, and ambiguous/echo-marked microphone segments reject the sample. Same-domain remembered voice matching still proposes microphone identities for confirmation. Choosing a previously confirmed user profile now restores that identity as well as its name.
- Action ownership accepts explicit conversational acceptance and discourse markers, including “Yeah, I can do that” and “And I'll be doing this.” Quotes must still match the cited speaker and surrounding source clause. Questions, negatives, hypothetical promises, reported speech, and ambiguous collective plans remain unresolved. Unique first-name requests can identify a speaker already named in the full roster. Named requests remain requests; they do not become accepted commitments. Owner labels and source quotes are preserved when the output language differs.
- Unresolved actions retain a fixed rejection reason. Their ownership, ordering, and shared limit with other participants' actions remain unchanged.

## Validation and limits

The tests use native policy fixtures, encrypted temporary stores, and generated PCM reference windows. They exercise data flow and rejection behavior; they do not prove human voice accuracy or compatibility with every live Meet layout. No UI tests run locally.

The first full focused run compiled the app and tests, passed 88 of 105 tests, and encountered protected-file access failures in 17 storage/service/lifecycle tests while the Mac was locked. The lock state was verified independently. File protection remains enabled; those tests require hosted CI or an unlocked session. Final local and hosted results are recorded in the PR.

Missing visual evidence from an earlier recording cannot be recreated by this change. A current live Meet recording is still needed to measure observation coverage and naming accuracy. Microphone profiles need an explicit initial confirmation and sufficient clean voice samples; an unidentified microphone is never assumed to be this Mac's user.

## Provider references

- Chromium documents enabling its macOS accessibility tree through `AXEnhancedUserInterface`: [Accessibility Technical Documentation](https://www.chromium.org/developers/design-documents/accessibility/).
- Meet changes tile arrangements with window size and presentations: [Learn how to view people in Google Meet](https://support.google.com/meet/answer/9292748?co=GENIE.Platform%3DDesktop&hl=en).
- Paired participant tiles can both have a speaking border, so a border alone is not an identity: [Pair tiles in Google Meet](https://support.google.com/meet/answer/14074665?hl=en).
- Apple's protected-file option permits creation while locked but prevents reopening until unlock: [completeFileProtectionUnlessOpen](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionunlessopen).
