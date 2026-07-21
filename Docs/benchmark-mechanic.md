# The Benchmark Mechanic — full spec

_Date: 2026-07-21. Elaborates §4 of `growth-plan.md`: make `lokalbot-cli benchmark` the local-AI test Mac reviewers run every chip cycle. Grounded in the tree: the headless benchmark pattern already exists (`--cotyping-bench`, `LokalBot/HeadlessCommands.swift:349`), the engines and timing hooks live in the app binary, `Benchmarks/` holds prior methodology, and the CLI is already embedded in `Contents/Helpers/` with PATH symlinks._

## 1. Why this works — the market mechanics

**Reviewers have a recurring, unmet need on a predictable calendar.** Every Apple silicon launch produces a 1–2 week wave of review content, and every reviewer faces the same problem: Geekbench and Cinebench are table stakes the audience has seen a hundred times, and "AI performance" — the segment every thumbnail now promises — has no good test. What they actually do today is time Ollama token output or run Geekbench AI: synthetic numbers that mean nothing to a viewer.

**Legibility is the differentiator.** "This Mac transcribed a one-hour meeting in 19 seconds" lands with a lay audience in a way tokens/s never will. Realtime-factor is intuitive, it demos well on camera (a progress bar racing a timestamp), and — the growth payoff — it *advertises the product while measuring the machine*. A synthetic benchmark markets nobody; a meeting-transcription benchmark is a product demo wearing a lab coat.

**The precedent is Blackmagic Disk Speed Test.** A free utility whose entire marketing value is that it appears, by name, on screen, in essentially every Mac review ever filmed. Cinebench did the same for Maxon. The tool that gets adopted into the standard review suite is named in every video, every cycle, forever, at zero marginal cost. That slot for "the local-AI test" is currently vacant.

**The calendar gives a hard deadline.** M-series Pro/Max refreshes have landed in Oct–Nov windows. Everything below should be shipped and seeded by **September**, with reviewer outreach through **October**, so the tool exists before embargo season rather than chasing it.

## 2. What to build

### 2.1 Architecture

The engines (ASR, llama-server, embeddings, diarization) live in the app binary, not the CLI — so the benchmark follows the established headless split:

- **`LokalBot --benchmark [--json <path>] [--quick]`** — a new `HeadlessCommands` case alongside `--process` / `--cotyping-bench`, orchestrating the workloads through the real pipeline components (`ProcessingPipeline`, `InferenceBroker` leases, the actual `TranscriptionEngine` implementations — no synthetic harness, the point is measuring what users get).
- **`lokalbot-cli benchmark`** — the discoverable front door: locates the app bundle (the installer symlink pattern already solves this), forwards to the headless command, streams its output. Reviewers should never need to know the app binary is involved.

### 2.2 Workloads and the headline number

| Sub-score | Workload | Metric |
| --- | --- | --- |
| Transcription | bundled sample meeting through the default ASR engine | realtime factor (×) |
| Diarization | same audio through FluidAudio | realtime factor (×) |
| Summarization | fixed transcript → recap via default local LLM | tokens/s |
| Recall | embed fixed chunk set | chunks/s |
| *(optional flag)* Cotyping | existing `--cotyping-bench` quality/latency run | tok/s + latency |

**Headline: the Meeting Score** — minutes of meeting fully processed (transcribe + diarize + summarize + index) per minute of wall clock, end to end. Reviewers need exactly one number for a bar chart; sub-scores are for the leaderboard detail view and for us. `--quick` runs a 2-minute slice for on-camera use; the full run uses the complete fixture.

### 2.3 The fixture — redistributable by construction

The e2e harness uses real audio, which can't ship. Generate a **synthetic ~10-minute two-speaker meeting**: a scripted, mildly comic product-standup dialogue (script checked into the repo), voiced by the on-device Kokoro TTS on two voices, mixed to the same two-track Me/Them layout the recorders produce. License-clean, reproducible from source by anyone, and — usefully — a script that name-drops LokalBot's own feature vocabulary, so every on-camera transcript scroll is subliminally on-message. Ship it as a versioned download (models are already fetched on first use; the fixture rides the same path) rather than fattening the DMG.

### 2.4 Fairness and determinism rules

Credibility with reviewers requires that two machines produce comparable numbers:

- **Versioned model set.** "Benchmark v1" pins exact models + quantizations (e.g. Parakeet v3 for ASR speed, the default Qwen for summaries, Qwen3-Embedding Q8). Results are tagged with the benchmark version; a new version resets the leaderboard columns rather than silently shifting them. First-run download for the benchmark set stays lean (~4 GB) with visible progress.
- **Auto-captured environment block** in every result: chip, core counts, RAM, macOS build, power source and low-power-mode state (`PowerSourceMonitor` exists), app version, thermal pressure at start. Cold and warm runs reported separately (model load time is itself an interesting number).
- **Run protocol printed by the tool**: plugged in, closed lid discouraged, second run is the reported run. Reviewers follow protocols happily when the tool states them.

### 2.5 Output — designed for camera first

The terminal scorecard *is* the marketing surface; it must look good at 4K on a video timeline:

- A clean ANSI card: big Meeting Score, sub-score rows with realtime-factor bars, the environment block, and the leaderboard URL on the last line (that URL appearing in B-roll is the whole point).
- `--json` writes the machine-readable result — the exact file the leaderboard accepts.
- Stretch: `--card out.png` renders the same scorecard as a shareable image via SwiftUI `ImageRenderer` (the Local Wrapped mechanic, §2 of the growth plan, wants this renderer anyway — build it once).
- Invariant note: the benchmark makes no network calls beyond first-run model/fixture downloads; results leave the machine only when a human submits them. Say so in the output footer — on brand, and one more privacy impression per video.

## 3. The leaderboard — UGC that compounds

- **Submission by pull request**: a `results/` directory (this repo or a dedicated `lokalbot-benchmarks` repo — dedicated keeps PR noise out of the app repo and gives a second starrable asset) where each submission is the `--json` file. CI validates the schema, then regenerates a static table + chart page published at `lokalbot.com/benchmarks` (the `web/` Vercel deploy already exists).
- **Why PRs and not a form**: every submission is a contributor, a star-adjacent event, and a public identity attached to the project — and it keeps the pipeline serverless, consistent with running no backend.
- **The chart is itself content.** The M1→M4 scaling curve for local AI answers the evergreen question "is it worth upgrading for on-device AI?" — a page that earns links independent of reviews, and refreshes automatically each chip cycle as submissions arrive.
- **Seeding**: maintainer's own hardware first, then a launch thread on r/LocalLLaMA — "run one command, PR your chip's numbers" — which doubles as that channel's launch post for the feature. Target: every chip generation M1→M4 covered within a month, including base/Air chips (low-end numbers are *more* useful to buyers than Max numbers).
- **Gaming**: stakes are low; schema validation + PR review + the environment block is enough. Obvious outliers get a review comment, not an arms race.

## 4. Reviewer outreach

- **Who**: the Mac performance-review circuit — the local-LLM-on-Mac specialist channels (this niche literally exists and is exactly on-message), the big general Mac channels, and written outlets that publish review benchmarks. Build the list once (~25 names) with per-channel notes; it's reusable every cycle.
- **The pitch is one paragraph** because the ask is 60 seconds: *"One command. One number your viewers can feel — how fast this Mac turns a meeting into notes, fully on-device. We'll add your result to the public leaderboard linked to your video."* The leaderboard link-back is the incentive: their video becomes the citation for that chip's row, driving them traffic each time someone checks the chart.
- **Timing**: packet (command, protocol one-pager, fixture pre-download instructions, press-usable scorecard renders) goes out ~2 weeks before expected announcement events, so it's sitting in inboxes when embargo units arrive.
- **Recycle the coverage**: after each launch wave, an aggregation page — "M5 vs M4 for local AI: what reviewers measured" — embedding the videos that ran it. SEO for the buying-decision query, backlinks for them, a second impression for us.

## 5. Effort, risks, and the honest failure mode

**Effort: M.** Fixture generation (script + Kokoro render + mixing), the `--benchmark` orchestration over existing components, the scorecard printer, JSON schema + CI + web page, outreach list. No new network surface, no new engine work.

**Risks:**
- *Thermal/config variance makes numbers contested* → the environment block + stated protocol + cold/warm split is the defense; contested numbers in comments are still engagement with the app's name on them.
- *Model-set drift* → versioned benchmark releases; never change the pinned set mid-version.
- *Apple or Primate Labs ships a better AI benchmark* → they'll be synthetic; the legibility moat ("a meeting, transcribed") and product tie-in remain unique. Worst case, LokalBot's benchmark is the niche local-LLM one — that niche is the target market anyway.
- *Reviewers ignore it in year one* → the leaderboard still works as community UGC and the r/LocalLLaMA seeding still lands; reviewer adoption is a multi-cycle campaign, and the packet gets re-sent every cycle for free.

**Success metrics** (all public, per the no-telemetry scoreboard): named appearances in review videos per chip cycle, leaderboard PRs from non-maintainers, referral traffic from YouTube descriptions to `lokalbot.com/benchmarks`, and stars on the benchmarks repo.

## 6. Build order

1. Fixture: script + Kokoro two-voice render + two-track mix, versioned download (S–M).
2. `--benchmark` headless command over existing engines, JSON output + environment capture (M).
3. `lokalbot-cli benchmark` forwarding + ANSI scorecard (S).
4. Schema + results repo + CI → `lokalbot.com/benchmarks` static page (S–M).
5. Seed hardware rows, r/LocalLLaMA thread (S).
6. Reviewer list + packet; send on the next launch-rumor cycle (S, recurring).

Steps 1–4 by September; 5–6 through October, ahead of the expected fall hardware window.
