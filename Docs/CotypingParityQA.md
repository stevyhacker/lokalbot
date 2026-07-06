# Cotyping Parity QA

This checklist keeps LokalBot's cotyping work aligned with the quality bar observed in Cotypist: a dedicated local model, prompt context, accepted-completion learning, streaming feedback, and measurable latency.

Parity defaults:

- Gemma 4 E4B Q5 XL is the default cotyping model. Cotyping always runs its own
  dedicated model on a separate `llama-server` instance — there is no option to
  reuse the summarization model, and no fallback to the bundled tiny model.
- Suggestion length defaults to 20 words, matching Cotypist/Cotabby's 12-20 word preset upper bound.
- Debounce defaults to 20 ms.
- Streaming partial suggestions default off, matching Cotypist/Cotabby.
- Suggestions appear instantly with no fade-in animation, and ghost text is
  always bare, matching Cotypist's understated inline presentation — the accept
  shortcut is configured (and discoverable) in Settings, never displayed beside
  the suggestion.
- Popup/mirror suggestions highlight the next word-sized accept chunk at stronger
  weight/contrast, matching Cotabby's preview card cue for what the next accept
  keypress will insert.
- Completion token budget follows Cotypist/Cotabby's English baseline: `ceil(words * 1.3)`, floor 5, doubled for multi-line up to 120.
- The dedicated cotyping `llama-server` launches with a 2048-token context window, matching Cotypist/Cotabby's local llama runtime configuration.
- Focus polling uses a Cotabby-style 50 ms active cadence, then stretches after
  sustained no-change captures so idle Accessibility reads back off without
  making post-keystroke suggestions feel delayed.
- Generation start and result apply reuse a focus snapshot only when the last
  Accessibility capture is at most 30 ms old; otherwise they re-read focus and
  drop stale decode output before painting, matching Cotabby's protection
  against focus switches during generation.
- Clipboard context matches Cotabby's relevance gate: the first pasteboard read
  is only a baseline, clipboard text must be freshly copied during the app
  session, it expires after five minutes, and it must share significant tokens
  with the current prompt prefix before it can condition a suggestion. Clipboard
  text is also sanitized before prompting: ANSI escapes, shell/Markdown-style
  separators, control characters, and punctuation-heavy noise are stripped, and
  long multi-line clips keep only lines overlapping the current prefix.
- Terminal gating matches Cotabby's default: standalone terminal apps are never
  assisted, and xterm.js integrated terminals are suppressed unless explicitly
  enabled in Settings.
- Accepted continuation text follows Cotabby's IME-safe path: while a composing
  input source is active, the accept path uses paste instead of a synthetic
  Unicode keystroke so marked-text input methods do not swallow the commit.
  The paste path first presses the host app's real Paste menu item, then falls
  back to a session-sourced Cmd-V event.
- Word-by-word acceptance follows Cotabby's space-less-script cadence: CJK,
  Japanese, Korean, Thai, and related runs are split with word segmentation
  instead of being accepted as one long whitespace-delimited token. Phrase
  acceptance stops at sentence/newline boundaries and CJK clause punctuation;
  ASCII commas stay inside the phrase.

## Mid-Word Word Completion (Cotypist parity)

Cotypist's signature behavior — "keep typing and it snaps to the word you
meant" — is a *required-prefix constrained decode* (its binary calls it
`requiredPrefix`/`remainingRequiredPrefix`). LokalBot reproduces it with three
cooperating layers:

- **Typo gate**: a word still being typed (no trailing space) that is a live
  prefix of a real word ("follo") is an unfinished word, not a typo — the gate
  returns `.proceed` so the LLM can complete it. Only fragments no dictionary
  word starts with ("recieve") get the inline correction / suppression
  (`CotypingTypoGate` + `CotypingSpellChecker.isCompletableWordPrefix`).
- **Token healing** (in-process runtime): the prompt is cut back to the last
  word boundary and the cut bytes (separator + fragment) become a decode
  constraint. Generation must re-produce them through naturally tokenized
  pieces — typically one boundary-merging token like " follow" against
  " follo" — then continues free. Only the text past the constraint is
  emitted, so the ghost extends the word (`CotypingTokenHealing`,
  `LlamaCotypingRuntime.generate(requiredPrefixUTF8:)`).
- **Normalizer guard**: on the HTTP fallback (no byte-level constraint), a
  whitespace-leading completion after a non-word fragment ("follo" + " up")
  is suppressed as `wordCompletionMismatch` rather than shown broken.

Note: Cotypist ships the *base* Gemma 4 E4B GGUF (`gemma-4-E4B-UD-Q5_K_XL`);
LokalBot uses the instruct variant (`gemma-4-E4B-it-UD-Q5_K_XL`). Base models
are stronger raw continuers; if completions still trail Cotypist in tone,
trialing the base GGUF as the cotyping model is the next lever.

## Automated Check

Run the in-app Cotyping tab's "Run cotyping check" action after selecting the
intended model, or headless:

```bash
"/Applications/LokalBot.app/Contents/MacOS/LokalBot" --cotyping-bench > bench.json
```

It exercises the 28 scenarios in `CotypingBenchmarkScenario.defaults`, in four
groups:

- Next-word continuations (email, chat, browser, scheduling, lists)
- **Word completions** — the caret ends on a fragment no dictionary word
  equals ("follo", "conversati", "Unterstüt"); the suggestion must begin with
  a word character and the expected tail (`expectedCompletionPrefixes`)
- Strictly-inside-word safety (text after the caret)
- Context/format robustness (questions, bullet lists, German, comma clauses)

Passing target:

- Normal scenarios return non-empty safe text.
- Word-completion scenarios extend the typed word (`wordCompletionPassed ==
  wordCompletionTotal` in the JSON/UI summary; 12/13 minimum observed on
  Gemma 4 E4B Q5 XL).
- Safety scenarios may suppress with an allowed reason.
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

The shared prompt set lives in `Benchmarks/Cotyping/prompts.tsv` — 25 prompts
across next-word, word-completion, valid-fragment, and typo groups, mirroring
the in-app benchmark scenarios. Both apps are driven by the same manifest, so
differences are pipeline differences, not prompt differences. Word-completion
prompts (`10-wc-*` … `20-wc-*`) are the Cotypist parity core: the accepted
insertion must begin with a word character that completes the typed fragment.

Record (per prompt, and overall):

- Time from pause to visible first suggestion.
- Whether the suggestion is grammatically valid.
- Whether it keeps the app/window topic.
- Whether accepting by word or phrase leaves correct spacing.
- Whether word-by-word acceptance in space-less scripts advances by a single
  word-sized segment, and phrase acceptance stops on CJK commas without stopping
  at ordinary English commas.
- Whether accepting under a composing IME commits the suggestion instead of
  reopening or extending marked text.
- Whether switching to another field while generation is running prevents the
  old field's suggestion from appearing.
- Whether terminal apps and integrated terminals stay quiet by default.
- Whether old or unrelated clipboard contents do not steer suggestions when
  clipboard context is enabled.
- Whether copied terminal/Markdown output is cleaned into prose-like context
  instead of leaking symbols such as `$`, backticks, fences, or ANSI escapes
  into suggestions.
- Whether suggestions appear steadily, and streamed updates, word-by-word
  acceptance, and post-accept reanchors do not flicker.
- Whether ghost text stays bare — no keycap badge next to inline or popup
  suggestions.
- Whether popup/mirror suggestions visually emphasize the next accept chunk
  rather than rendering the whole preview at the same strength.
- Whether it avoids code editors, terminals, secure fields, and excluded domains.

For the repeatable capture + merged report:

```bash
COTYPING_COMPARE_ACCEPT=1 Scripts/compare-cotyping.sh cotypist /tmp/cotyping-cotypist
COTYPING_COMPARE_ACCEPT=1 Scripts/compare-cotyping.sh lokalbot /tmp/cotyping-lokalbot
"/Applications/LokalBot.app/Contents/MacOS/LokalBot" --cotyping-bench > /tmp/bench.json
Benchmarks/Cotyping/side_by_side.py \
  --cotypist-dir /tmp/cotyping-cotypist --lokalbot-dir /tmp/cotyping-lokalbot \
  --engine-json /tmp/bench.json --output Benchmarks/Cotyping/results/<date>.md
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
changes in a plain AppKit editor. It does not exercise System Events keystrokes
or Tab acceptance, and many cotyping apps deliberately ignore one-shot value
changes, so a no-suggestion probe is weak evidence rather than a product
failure.

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
