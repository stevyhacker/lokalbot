# Cotyping Parity QA

This checklist keeps LokalBot's cotyping work aligned with the quality bar observed in Cotypist: a dedicated local model, prompt context, accepted-completion learning, streaming feedback, and measurable latency.

## Automated Check

Run the in-app Cotyping tab's "Run cotyping check" action after selecting the intended model. It exercises the default benchmark scenarios in `CotypingBenchmarkScenario.defaults`:

- Email follow-up
- Chat ownership
- Browser prose
- Mid-word continuation

Passing target:

- Every scenario returns non-empty safe text.
- No scenario is suppressed by duplication, echo, or insertion-safety gates.
- p95 latency is at or below 2000 ms.
- Expected-term hits are reviewed as a quality signal, not a hard pass/fail.

## Manual Side-by-Side

Use the same prompts in Cotypist and LokalBot with Gemma 4 E4B Q5 XL active in LokalBot. Qwen3.5 2B and LFM2.5 1.2B remain useful latency comparison points:

1. Mail: `Hi Sarah,\nThanks for sending this over. I wanted to follow`
2. Slack: `Sounds good, I can take`
3. Browser comment box: `The main tradeoff is`
4. Mid-word: preceding `Please rec`, trailing `eive the files when ready.`

Record:

- Time from pause to visible first suggestion.
- Whether the suggestion is grammatically valid.
- Whether it keeps the app/window topic.
- Whether accepting by word or phrase leaves correct spacing.
- Whether it avoids code editors, terminals, secure fields, and excluded domains.

For repeatable screenshot capture:

```bash
Scripts/compare-cotyping.sh cotypist /tmp/cotyping-cotypist
Scripts/compare-cotyping.sh lokalbot /tmp/cotyping-lokalbot
```

The script opens TextEdit, clicks into the document, types each prompt as real
keystrokes, waits for the active cotyping app, and captures the TextEdit window
region as one PNG per prompt. It requires
Accessibility for the shell and Screen Recording for `screencapture`.
Set `COTYPING_COMPARE_FIRST_WAIT_SECONDS` or `COTYPING_COMPARE_WAIT_SECONDS` if
the first Q5 XL model load needs more time on a cold run.

## Local Learning Check

1. Enable "Learn from accepted completions".
2. Accept at least three email/chat continuations.
3. Re-run a similar prompt in the same app/window context.
4. Confirm the prompt uses learned examples only after acceptance and the learned example count increases.
5. Delete learned writing data from Settings and confirm the count returns to zero.

## Model Prep Check

Use "Prepare high-quality cotyping" in Cotyping, Models, or Settings.

Expected behavior:

- Dedicated cotyping is enabled.
- Gemma 4 E4B Q5 XL is selected.
- The Hugging Face download starts if the model is missing.
- Once downloaded, the status shows ready and cotyping uses the dedicated server.

Gemma 4 E4B Q5 XL reuse is still supported: if Cotypist already has the parity
GGUF in its Application Support folder, LokalBot uses that file read-only
instead of redownloading it.
