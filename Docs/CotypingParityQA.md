# Cotyping Parity QA

This checklist keeps LokalBot's cotyping work aligned with the quality bar observed in Cotypist: a dedicated local model, prompt context, accepted-completion learning, streaming feedback, and measurable latency.

Parity defaults:

- Gemma 4 E4B Q5 XL is the default cotyping model. Cotyping always runs its own
  dedicated model on a separate `llama-server` instance — there is no option to
  reuse the summarization model, and no fallback to the bundled tiny model.
- Suggestion length defaults to 20 words, matching Cotypist/Cotabby's 12-20 word preset upper bound.
- Debounce defaults to 20 ms.
- Streaming partial suggestions default off, matching Cotypist/Cotabby.
- Completion token budget follows Cotypist/Cotabby's English baseline: `ceil(words * 1.3)`, floor 5, doubled for multi-line up to 120.
- The dedicated cotyping `llama-server` launches with a 2048-token context window, matching Cotypist/Cotabby's local llama runtime configuration.
- Focus polling uses a Cotabby-style 80 ms active cadence, then stretches after
  sustained no-change captures so idle Accessibility reads back off without
  making post-keystroke suggestions feel delayed.
- Generation start and result apply reuse a focus snapshot only when the last
  Accessibility capture is at most 30 ms old; otherwise they re-read focus and
  drop stale decode output before painting, matching Cotabby's protection
  against focus switches during generation.
- Clipboard context matches Cotabby's relevance gate: the first pasteboard read
  is only a baseline, clipboard text must be freshly copied during the app
  session, it expires after five minutes, and it must share significant tokens
  with the current prompt prefix before it can condition a suggestion.
- Terminal gating matches Cotabby's default: standalone terminal apps are never
  assisted, and xterm.js integrated terminals are suppressed unless explicitly
  enabled in Settings.
- Accepted continuation text follows Cotabby's IME-safe path: while a composing
  input source is active, the accept path uses paste instead of a synthetic
  Unicode keystroke so marked-text input methods do not swallow the commit.
  The paste path first presses the host app's real Paste menu item, then falls
  back to a session-sourced Cmd-V event.

## Automated Check

Run the in-app Cotyping tab's "Run cotyping check" action after selecting the intended model. It exercises the default benchmark scenarios in `CotypingBenchmarkScenario.defaults`:

- Email follow-up
- Chat ownership
- Browser prose
- Mid-word safety

Passing target:

- Normal scenarios return non-empty safe text.
- Safety scenarios may suppress when the model proposes an unsafe mid-word join
  or trailing-text duplication.
- p95 latency is at or below 2000 ms.
- Expected-term hits are reviewed as a quality signal, not a hard pass/fail.

- **Generation runtime — DONE.** Cotyping now decodes the built-in GGUF model
  in-process via `libllama` (`b9844`), holding a persistent KV cache and
  re-prefilling only the typed suffix (`LocalLlamaCotypingEngine` →
  `LlamaCotypingRuntime`). The HTTP `llama-server` path remains as the fallback
  for non-GGUF backends, when the in-process runtime is toggled off
  (`cotypingInProcessRuntime`), or on load failure. A/B latency is measured by
  `CotypingBenchmarkRunner.runAB(local:http:...)` over the default scenarios
  (TTFT + p95 deltas).

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
- Whether accepting under a composing IME commits the suggestion instead of
  reopening or extending marked text.
- Whether switching to another field while generation is running prevents the
  old field's suggestion from appearing.
- Whether terminal apps and integrated terminals stay quiet by default.
- Whether old or unrelated clipboard contents do not steer suggestions when
  clipboard context is enabled.
- Whether it avoids code editors, terminals, secure fields, and excluded domains.

For repeatable screenshot capture:

```bash
Scripts/compare-cotyping.sh cotabby /tmp/cotyping-cotabby
Scripts/compare-cotyping.sh cotypist /tmp/cotyping-cotypist
Scripts/compare-cotyping.sh lokalbot /tmp/cotyping-lokalbot
```

The script opens TextEdit, clicks into the document, types each prompt as real
keystrokes, waits for the active cotyping app, and captures the TextEdit window
region as one PNG per prompt. It also writes `*.document.txt` with the TextEdit
document text after the wait. Set `COTYPING_COMPARE_ACCEPT=1` to press Tab after
the screenshot and write `*.accepted.txt`, which is the source of truth for
spacing/partial-accept behavior. It requires
Accessibility for the shell and Screen Recording for `screencapture`.
Set `COTYPING_COMPARE_FIRST_WAIT_SECONDS` or `COTYPING_COMPARE_WAIT_SECONDS` if
the first Q5 XL model load needs more time on a cold run.

If the shell does not have Accessibility and fails with
`osascript is not allowed assistive access`, the fallback probe can capture a
lower-confidence signal without touching TextEdit documents:

```bash
swiftc Scripts/cotyping-probe.swift -o /tmp/cotyping-probe
/tmp/cotyping-probe --prompt "I wanted to follow" --slug 01-follow-up --output-dir /tmp/cotyping-probe-lokalbot --wait 12
```

The probe opens its own temporary AppKit text window, inserts text internally,
captures the full screen, and writes `*.document.txt`, `*.rect`, and `*.png`.
Use it only to inspect whether a target app responds to accessibility value
changes in a plain AppKit editor. It does not send real keystrokes, does not
exercise Tab acceptance, and is not a substitute for the TextEdit side-by-side.

For repeatable backend latency/output checks against LokalBot's dedicated
Gemma Q5 XL `llama-server`:

```bash
Benchmarks/Cotyping/run_llama_server_benchmark.py --surface-context --repetitions 3
```

This records first streamed chunk latency, final latency, stop reason and raw
model text for the same prompts. It is a backend microbenchmark, not a UI
parity test; use it to verify prompt/sampling/server changes before doing the
side-by-side screenshot pass.

## Local Learning Check

1. Enable "Learn from accepted completions".
2. Accept at least three email/chat continuations.
3. Re-run a similar prompt in the same app/window context.
4. Confirm the prompt uses learned examples only after acceptance and the learned example count increases.
5. Delete learned writing data from Settings and confirm the count returns to zero.

## Model Prep Check

Cotyping always runs its own dedicated model. Use "Prepare high-quality cotyping"
in Cotyping, Models, or Settings to fetch it.

Expected behavior:

- Gemma 4 E4B Q5 XL is the selected cotyping model by default.
- The Hugging Face download starts if the model is missing (~6.66 GB).
- Until the model is present, cotyping reports that it needs the download — there
  is no fallback to the bundled summarization model.
- Once downloaded, the status shows ready and cotyping uses the dedicated server.

LokalBot always downloads and manages its own copy of the model under its storage
folder. It does not reuse another app's model files.
