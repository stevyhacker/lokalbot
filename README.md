<div align="center">

<img src="Assets/lokalbot-icon.svg" width="120" alt="LokalBot icon" />

# LokalBot

**Private AI meeting notes for your Mac — plus inline autocomplete, dictation, and a day timeline.**

Records both sides of the call and writes the recap with on-device models by default. No account, no telemetry, and no LokalBot cloud.

![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-required-1f6feb)
![Local-first](https://img.shields.io/badge/local--first-on--device-2ea043)
![Price](https://img.shields.io/badge/price-free-2ea043)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-2ea043)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-FA7343?logo=swift&logoColor=white)

[**Download**](#download) · [Features](#features) · [How it works](#how-it-works) · [Build from source](#build-from-source) · [FAQ](#faq) · [Contributing](#contributing)

</div>

---

LokalBot records both sides of your calls — no bot joining — then transcribes, summarizes, and indexes them for search on your Mac by default. Around that core it grew into a local-first AI workspace: **Cotyping** suggests text inline as you type in any app, **Dictation** turns a held **⌥ Space** into on-device speech-to-text wherever your cursor is, a private timeline shows where your day went, and **Agent Mode** embeds a coding agent that runs on the same local model. Built-in models run on Apple Silicon. Network access is limited to model downloads, update checks, optional Agent Mode setup, and remote inference origins you explicitly approve. There is no LokalBot account, telemetry endpoint, or hosted AI backend.

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/superapp-diagram.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/superapp-diagram-light.svg">
  <img alt="LokalBot — one on-device model powering meetings, Cotyping, chat, search, day timeline, agent CLI, and bring-your-own models. Local by default, with optional approved remote inference." src="Assets/superapp-diagram-light.svg" width="620">
</picture>

<sub>One local model, your whole workday — on-device by default.</sub>

</div>

<div align="center">

<img src="Assets/screenshots/hero.gif" alt="LokalBot tour: meeting recap, speaker-labeled transcript, search, day timeline, and inline autocomplete" width="880" />

<sub>A quick tour — meeting recap → speaker-labeled transcript → search → day timeline → inline autocomplete.</sub>

</div>

## Why LokalBot

| | |
| --- | --- |
| **Your whole workday** | Meetings, notes, search, day tracking, and inline autocomplete, all in one app. |
| **Local by default** | Audio remains on your Mac; built-in transcription, summaries, search, and writing tools run there too. |
| **Check, don't trust** | Audit the source or network traffic. You will see model/update downloads and only the remote inference origins you approve. |
| **Free, no API keys** | Pick the best local model for each job and download it once. |
| **Open source** | Read every line, or build it yourself. |

**Switching from a cloud notetaker?** If you're leaving Granola, Otter, Rewind, or Superwhisper — or your company just banned cloud notetakers — the difference that matters is where the AI runs and where your audio ends up: [vs Granola](https://www.lokalbot.com/lokalbot-vs-granola) · [vs Rewind](https://www.lokalbot.com/lokalbot-vs-rewind) · [vs Superwhisper](https://www.lokalbot.com/lokalbot-vs-superwhisper) · [vs Hyprnote](https://www.lokalbot.com/lokalbot-vs-hyprnote)

## See it in action

**Records the call, writes the recap.** Pick any meeting and get a structured summary plus a speaker-labeled (Me / Them) transcript.

<div align="center"><img src="Assets/screenshots/recap.gif" alt="Browsing meeting recaps and speaker-labeled transcripts" width="860"></div>

**Search everything you've heard.** Full-text and semantic search across transcripts and summaries — click a hit to play from that exact second.

<div align="center"><img src="Assets/screenshots/search.gif" alt="Searching across meetings, results highlighted" width="860"></div>

<details>
<summary><strong>More screens</strong> — day timeline, cotyping, models, chat</summary>

|  |  |
| :--: | :--: |
| <img src="Assets/screenshots/timeline.png" alt="Day timeline" width="420"><br>**Day timeline** — see where your time went | <img src="Assets/screenshots/cotyping.png" alt="Cotyping inline autocomplete" width="420"><br>**Cotyping** — inline AI autocomplete |
| <img src="Assets/screenshots/models.png" alt="Model catalog" width="420"><br>**Models** — pick or download any model | <img src="Assets/screenshots/chat.png" alt="Chat with your meetings" width="420"><br>**Chat** — ask across your library |

</details>

## Features

- **Records both sides of the call.** Auto-detects Zoom, Teams, Meet, Slack, Webex, and FaceTime, then captures *you* and *them* on two synced tracks — speaker labels for free.
- **Follow the call live.** A live meeting view during the call: quick notes that land in the finished meeting, plus an opt-in rolling transcript while people talk.
- **Transcribes locally.** Recommended default: IBM Granite Speech 4.1; switch to Parakeet for speed, Whisper for 99 languages, or Qwen3-ASR for harder recordings.
- **Writes the recap automatically.** A TL;DR with decisions and action items the moment the call ends. Pick a notes template, summary language, and re-run anytime.
- **Search every word you've heard.** Full-text *and* meaning-based search across transcripts, summaries, and on-screen text. Click a hit to play from that exact second.
- **Chat with your meetings.** Ask "what did we decide?" or "find the action items" in plain language — answers are grounded in your library. Kokoro TTS can read summaries and answers aloud — on-device, like everything else.
- **Cotyping — inline AI autocomplete.** Ghost text as you type in almost any app; press **Tab** to accept. Runs its own dedicated on-device model (recommended Gemma 4 · E4B). Opt-in.
- **Dictation — voice typing anywhere.** Hold **⌥ Space**, talk, release: your words are transcribed on-device and pasted at the cursor. Pauses your music first; audio is deleted after transcription. Opt-in.
- **See where your day went.** A private timeline of apps and meetings, a generated daily digest, and an "ask your day" box.
- **Private by construction.** Optional screenshots are AES-GCM encrypted and auto-delete after 14 days. Password fields and excluded apps are never read.
- **Bring your own model.** Use the included llama.cpp runtime with a GGUF you choose, or point at Ollama, any OpenAI-compatible server, or Apple Intelligence.
- **Agent Mode — a coding agent on your model.** The embedded pi coding agent runs against the same local Main LLM, fully offline; `write` / `edit` / `bash` wait behind native approval cards. Opt-in.
- **Built for coding agents.** `lokalbot-cli` gives agents read-only access to your meeting library — as a CLI, an installable agent skill, or an MCP server with a one-click bundle for Claude Desktop. Off by default.

<details>
<summary><strong>Recording &amp; meeting detection</strong> — the details</summary>

- **Detection:** polls for known meeting apps (Zoom, Teams, Slack, Webex, FaceTime) plus mic-in-use, backed by event-driven signals — Core Audio property listeners on the default input (with device-change re-arm), `NSWorkspace` launch/quit, and an `AudioSourceMonitor` that treats *silent → producing-output* transitions as meeting candidates (catches muted calls and tabs opened before the mic). **Browser meetings** (Google Meet, Jitsi, Whereby) are detected from the focused-window title when Accessibility is granted; the system-audio tap captures the browser. Auto-start is configurable (auto / ask / manual); auto-stop debounces (default 60 s, configurable).
- **Two synchronized tracks:** `mic.m4a` (AVAudioEngine) = **Me**, `system.m4a` (Core Audio process tap on the meeting app's PID → aggregate device → AAC) = **Them** — free diarization. The engine re-installs its tap on `AVAudioEngineConfigurationChange` (AirPods/USB switches no longer truncate the recording), drains the converter on stop (keeps trailing audio), stops cleanly if the captured app exits, and encodes AAC off the real-time IOProc thread.
- **UI:** menu-bar item (record state, start/stop, recent meetings, pause/resume) plus a main window (meeting list, Show in Finder, in-app playback). While a recording runs, the meeting opens in a **live view**: a quick-notes pad (notes land in the finished meeting) and an opt-in rolling live transcript.

</details>

<details>
<summary><strong>Transcription &amp; speakers</strong> — engines and diarization</summary>

Engines (Settings → Models; CoreML/MLX, in-process, Neural Engine/Metal):

| Engine | Coverage | Notes |
| --- | --- | --- |
| **IBM Granite Speech 4.1** | high-accuracy local ASR | **recommended** |
| **Parakeet TDT 0.6B v3** | 25 languages, ~190× realtime | fastest local option |
| **Parakeet TDT 0.6B v2** | English only | slightly higher recall |
| **Qwen3-ASR 1.7B** (MLX, ~3.2 GB) | 52 languages/dialects | best Qwen accuracy tier for harder recordings |
| **Qwen3-ASR 0.6B** (MLX, ~0.7 GB) | global coverage | compact tier |
| **Whisper large-v3 turbo** (WhisperKit, ~1.6 GB) | 99 languages | word timestamps; wide-language fallback |
| **SenseVoice / GigaAM** (ONNX) | CJK/Cantonese/English, Russian | specialist coverage |
| **Cohere Transcribe** (2B) | 14 languages | legacy — hidden unless already installed (no language detection, timestamps, or diarization) |

Models auto-download on first use (Hugging Face; the ONNX specialists fetch sherpa-onnx archives from GitHub) and are cached under Application Support.

- **Speaker attribution:** mic track = **Me**, system track = **Them**, merged by timestamp into `transcript.json` + `transcript.md`. When calendar detection matches the meeting to an event, the remote speaker is named from the invite's attendees instead of "Them".
- **Neural diarization:** Settings → Recording → "Split 'Them' by speaker" runs FluidAudio's offline pyannote-community-1 pipeline on `system.m4a` after transcription and relabels segments "Them 1 / Them 2 / …" (threshold 0.70, step ratio 0.15, min segment 0.3 s). Enabled by default; first run downloads ~100 MB of CoreML models.

</details>

<details>
<summary><strong>Summarization &amp; notes</strong> — backends, templates, pipeline</summary>

- **Backends** (Settings → Models): **Built-in** (included localhost llama.cpp runtime; choose/download a GGUF model) · **Apple Intelligence** (FoundationModels, macOS 26+, gated so the app still builds/launches on 15.0) · **Ollama** · **any OpenAI-compatible server** (LM Studio, vllm-mlx, …). Non-loopback endpoints require explicit origin approval before context is sent.
- **Output:** `summary.md` with TL;DR / Key points / Decisions / Action items / Open questions. Map-reduce for long meetings; `<think>` reasoning blocks are stripped.
- **Templates & language:** pick a notes template (Meeting / Lecture / Study guide / Podcast / Free-form) and a summary language (auto-detected via `NLLanguageRecognizer`, with Simplified / Traditional / Cantonese handling). Prompt budgeting (`TokenCountEstimator`, `PromptContextSanitizer`, `PromptSectionBudget`) keeps prompts within the model's context.
- **Pipeline:** runs automatically when a recording stops (configurable); serial queue with per-meeting status in the UI, plus a Process menu for manual re-runs.

</details>

<details>
<summary><strong>Built-in LLM runtime</strong> — llama.cpp &amp; model catalog</summary>

- `LlamaServer` copies the vendored `llama-server` out of Resources into Application Support on first run (never executes from inside the bundle), spawns it (`-ngl 99 --jinja`, port 17872), health-checks `/health`, restarts on model switch, and terminates on quit.
- **Inference broker:** the three shared llama-servers — main (17872), embeddings (17873), cotyping fallback (17874) — are lease-managed by `InferenceBroker`: consumers take per-request leases, a server with no active leases unloads after a short linger, and loaded models sit under a RAM residency budget with LRU eviction. Settings → Advanced shows a live **resource monitor** of what's loaded and which lease is pinning it.
- **Model catalog** (Settings → Models) — download / cancel / delete with progress, radio-select the active model. Qwen "thinking" is disabled for summaries via `chat_template_kwargs`. The Models tab also manages the dedicated cotyping model, the embedding model, and the **Kokoro** TTS voice (sherpa-onnx; downloads once, then reads summaries and chat answers aloud offline).

| Model | Size | Best for |
| --- | --- | --- |
| Qwen 3.5 · 0.8B | ~0.5 GB | tiny downloadable fallback |
| LFM2.5 · 1.2B Instruct | ~0.9 GB | fast cotyping |
| Qwen 3.5 · 2B | 1.3 GB | lightweight cotyping |
| Qwen 3.5 · 4B | ~2.8 GB | balanced summaries |
| Gemma 4 · E4B | ~6.7 GB | recommended cotyping |
| LFM2.5 · 8B MoE | 5.2 GB | fast summaries |
| Qwen 3.6 · 35B-A3B | 17.7 GB | recommended summaries |
| Qwen 3.6 · 27B | ~16.8 GB | maximum-quality dense summaries |
| Gemma 4 · 12B | ~7.5 GB | multimodal-family summaries |

- **Browse Hugging Face** in-app: search GGUF repos, list `.gguf` files, download — resilient (synchronous temp-file rescue, outcome classification, GGUF magic-byte validation). `HardwareCapabilityProbe` surfaces a per-model fit advisory under Settings → System.

</details>

<details>
<summary><strong>Search &amp; player</strong> — full-text + semantic, synced playback</summary>

- **Index:** SQLite + FTS5 (`lokalbotv3.sqlite` — system SQLite, no dependency) over titles, transcript segments, summaries, and OCR'd screen text. Segment rows carry their audio timestamp; incremental re-index by file mtime on launch and after each pipeline run.
- **Semantic search:** transcript/summary chunks embedded with Qwen3-Embedding 0.6B GGUF on a second llama-server instance (port 17873, `--embeddings --pooling mean`); vectors live in SQLite with a model-version marker and queries are brute-force cosine — instant at personal scale, zero extra dependency. Ask → All adds a "Related (semantic)" section for meaning-matches keywords miss; toggle in Ask. Qwen3-VL-Embedding 2B is tracked for screenshot/slide retrieval once image-vector indexing is added.
- **UI:** sidebar Timeline | Meetings | Ask | Type | Agent | Settings; search lives in **Ask** — debounced search-as-you-type (last term prefix-matched), All / Transcripts / Summaries / Screen facets, «highlighted» snippets; clicking a transcript hit opens the meeting and plays from that timestamp.
- **Player:** mic + system tracks play in sync (shared device-time anchor); seek bar; click any transcript line to jump the audio there; the currently-playing segment is highlighted.

</details>

<details>
<summary><strong>Ask assistant</strong> — conversational Q&amp;A over your library</summary>

- **Chat with your meetings:** pressing ↵ in the **Ask** section escalates your query to a conversational assistant over your library — ask what was decided, find action items, or search transcripts in natural language. A small ReAct agent (`ChatAgent`) reuses the selected `TextEngine` and calls tools to ground every answer. With the built-in default it stays on the Mac; an approved remote backend receives the prompt context needed to answer.
- **Tools (pi-agent style, mirroring the CLI):** `search_meetings` (FTS5 keyword + optional semantic search), `list_meetings` (filter by title), and `get_meeting` (read a meeting's summary or transcript). The agent picks a tool, reads the observation, then answers — citing meeting titles and dates, and saying so plainly when nothing matches.
- **Robust protocol:** tools are advertised in the system prompt with the recent-meeting list as ambient context; a tool call is parsed from a JSON object **or** a model's native `name(arg=…)` function-call form (smaller Qwen models emit the latter), with a tolerant fallback to a plain answer so a sloppy reply never hard-fails.
- **Reuses the configured backend:** built-in llama-server by default, or Ollama / OpenAI-compatible / Apple Intelligence — the same Settings → Models choice.

</details>

<details>
<summary><strong>Day tracking</strong> — timeline, digests, "ask your day"</summary>

- **Opt-in:** day tracking is off by default. A dedicated onboarding step (or Settings → Day tracking) turns on activity sampling and, separately, screenshots — finishing setup never silently enables either.
- **Sampler:** frontmost app + focused-window title (Accessibility; degrades to app-name-only) every 5 s, idle-aware (3 min), minimum 5 s block, pause/resume from the menu bar. Stored in `activity_blocks` (same SQLite db).
- **Timeline:** per-day colored block bar with hover details, time-by-app totals with %, and day navigation. An **Ask your day** box answers free-form questions from the day's activity blocks + OCR'd screen text + meetings via the local LLM.
- **Day digest:** "Generate digest" runs the configured LLM over the day's blocks + meetings + OCR'd text → `journal/YYYY-MM-DD.md` (What I worked on / Meetings / Time allocation).

</details>

<details>
<summary><strong>Cotyping</strong> — inline AI autocomplete</summary>

- **Ghost text everywhere:** as you type in almost any macOS text field, a gray suggestion appears next to the cursor; press **Tab** to accept (a word at a time, or the whole thing — Type → Cotyping), or keep typing / press **Esc** to dismiss. Built on the same loop as [Cotabby](https://cotabby.app): an Accessibility poll resolves the focused field + caret, a `CGEventTap` watches keystrokes (and swallows the accept key only while a suggestion shows), a borderless click-through `NSPanel` renders the ghost at the caret, and accepted text is inserted as synthetic Unicode keystrokes.
- **Its own dedicated on-device model:** cotyping decodes a dedicated model (recommended **Gemma 4 · E4B**) **in-process via libllama** for low latency, with the localhost `llama-server` as the fallback. The prompt treats the model as a pure text-continuer; raw output is cleaned by a shared normalizer (strips chat/`<think>` scaffolding, prompt echoes, and trailing-text duplication; collapses to one line).
- **Opt-in & private:** off by default; needs **Accessibility** + **Input Monitoring**. Never reads password/secure fields; honors a per-user app exclusion list (preseeded with password managers and terminals).
- **In-app preview:** the **Type** section has a live playground that runs the real pipeline on text typed *inside LokalBot* — try it with zero system permissions. Quick-toggle from the menu bar.

</details>

<details>
<summary><strong>Dictation</strong> — system-wide voice typing</summary>

- **Hold ⌥ Space and talk** (or switch to toggle mode): a floating pill shows recording state and a live transcript while you speak; release, and the text is pasted into the focused app — or copied to the clipboard instead (Type → Dictation).
- **Your ASR, prewarmed:** dictation reuses the transcription engine and language you picked under Models (Granite, Parakeet, Whisper, Qwen3-ASR, …) and prewarms it when the shortcut is armed, so short dictations start instantly.
- **Considerate capture:** playing media (Spotify, Music, browsers, VLC, …) is paused before recording starts; audio goes to a local PCM scratch file and is deleted right after transcription.
- **Opt-in & private:** off by default; needs the Microphone grant plus Input Monitoring for the global shortcut. Audio, transcription, and paste all happen on-device.

</details>

<details>
<summary><strong>Agent Mode</strong> — an embedded coding agent on your local model</summary>

- **A coding agent in the sidebar:** the **Agent** section embeds the pi coding agent, preconnected to the same local Main LLM through an OpenAI-compatible shim — a coding agent running on your own GGUF (or whichever backend you configured). Sessions run in tabs, and an active session holds an inference lease so the model stays loaded while you work.
- **Offline by construction:** pi runs with `--offline`, version checks and crash reporting disabled. Enabling Agent Mode downloads its runtime once — a checksum-verified Bun release from GitHub plus the pi package from npm, pinned by a lockfile bundled with LokalBot — and nothing is fetched after that.
- **You approve the side effects:** `write` / `edit` / `bash` tool calls pause behind native approval cards before anything touches disk or shell; read-only tools run freely.
- **Headless:** `LokalBot --agent "<prompt>"` runs one agent turn from the terminal (see Headless flags).

</details>

<details>
<summary><strong>Screenshots, OCR &amp; privacy</strong> — capture, encryption, retention</summary>

- **Capture:** off by default, enabled only by the onboarding day-memory step or Settings → Day tracking. When on: ScreenCaptureKit screenshot of the main display every N minutes (default 3, Settings slider), downscaled to ≤1500 px, HEIC. Skipped when idle (3 min), paused, locked, or when an excluded app is frontmost. Requires the Screen Recording permission (which LokalBot uses for nothing else — system audio rides an entitlement, not this grant).
- **OCR:** Vision (`VNRecognizeTextRequest`, on-device) runs immediately; text goes into `ocr_fts` (searchable under Ask → Screen) and feeds day digests and Ask-your-day.
- **Encryption & retention:** each screenshot is AES-GCM sealed with a per-install key in the macOS Keychain; pixels auto-delete after N days (default 14, Settings stepper), and OCR text follows the same retention unless you opt into keeping it forever (Settings → Privacy). The timeline shows a decrypted thumbnail filmstrip.
- **Exclusions:** comma-separated app list (preseeded with password managers); excluded time logs as "Private" — no titles, no screenshots.

</details>

## How it works

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/architecture-diagram.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/architecture-diagram-light.svg">
  <img alt="LokalBot's local-first pipeline: capture (mic as Me via AVAudioEngine, system audio as Them via a Core Audio process tap) → transcribe on-device → summarize with the built-in local model or an explicitly approved server → index locally in SQLite. Model and update downloads use the network." src="Assets/architecture-diagram-light.svg" width="880">
</picture>

</div>

1. **It notices the meeting.** LokalBot watches for calls and starts recording both sides on its own — or you start it from the menu bar.
2. **It transcribes and summarizes.** On-device models turn the audio into a labeled transcript and a structured recap the moment the call ends.
3. **Your library stays on your Mac.** Everything lands in a local library you can search, replay, and hand to trusted tools. Only approved remote inference receives request context.

## Privacy

Privacy is the architecture, not a slogan. Audio, transcripts, summaries, embeddings, screenshots, and activity live in local SQLite and files under your account. There is no account or telemetry. Audio is never sent to a LokalBot service; text context leaves only for a non-loopback inference origin you explicitly approve.

The only outbound connections LokalBot ever makes:

1. **One-time model downloads** the first time you use an engine — GGUF / CoreML / MLX weights from Hugging Face, sherpa-onnx archives (SenseVoice / GigaAM speech models, the Kokoro voice) from GitHub. After that they run fully offline.
2. **A backend you explicitly configure** — if you point summaries or chat at Ollama, an OpenAI-compatible server, or Apple Intelligence, traffic goes only where you send it. The built-in llama.cpp runtime is localhost-only.
3. **Agent Mode setup, if you enable it** — a one-time, checksum-verified download of the Bun runtime (GitHub) and the lockfile-pinned pi package (npm). The agent itself runs offline against your local model.
4. **App updates** via Sparkle — off by default; run a manual check or opt into scheduled checks.

Don't take our word for it: run Little Snitch (or `lsof -i -nP | grep LokalBot`) through a full record → transcribe → summarize cycle and watch it stay silent. Optional screenshots are AES-GCM sealed with a per-install Keychain key and auto-delete; password fields and excluded apps are never read.

## Download

> [!NOTE]
> Releases are published on GitHub as a `.dmg`. Selected models download on first use; after preparation, built-in inference works offline. Update checks and optional remote/agent features still use the network when enabled.

- **[Download the latest release](https://github.com/stevyhacker/lokalbot/releases/latest)** · [all releases and notes](https://github.com/stevyhacker/lokalbot/releases)

**Requirements**

- Apple Silicon Mac (M1 or later)
- macOS 15.0 or later
- Disk for models varies by the engines you pick (~0.5–18 GB)

## Build from source

You'll need **Xcode 16+** with a signing team, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and CMake (`brew install xcodegen cmake`).

```bash
git clone https://github.com/stevyhacker/lokalbot.git
cd lokalbot
xcodegen generate
open LokalBot.xcodeproj
```

Set your team under **Signing & Capabilities**, pick a scheme, and Run:

| Scheme | Bundle id | Notes |
| --- | --- | --- |
| **LokalBot** | `me.dotenv.LokalBot` | production; Sparkle auto-update compiled in |
| **LokalBot Dev** | `me.dotenv.LokalBot.dev` | `LOKALBOT_DEV` flag; Sparkle compiled out. A distinct bundle id keeps its own Mic / Screen Recording / Accessibility grants, so running from Xcode never disturbs the released app |

The first build runs `Scripts/fetch-llama.sh` (a pre-build phase), which verifies and compiles pinned llama.cpp source (`b9844` — server + dylibs, ~36 MB) for macOS 15 into `Vendor/`, then copies it into the app bundle. GGUF models are not bundled with the app; built-in models download into Application Support when first needed. On first recording, macOS prompts for **Microphone** and **System Audio Recording**; transcription and recap models prepare automatically before their first use.

> The shipped app is **LokalBot** (`me.dotenv.LokalBot`); the Xcode project and scheme are named `LokalBot`.

## Configuration

Everything lives in **Settings** — five tabs with a search box that finds any setting — plus per-feature controls in the **Type** section:

- **General** — launch at login, menu-bar-only mode, permission status + repair, storage location, update checks.
- **Recording** — auto-record behavior, calendar-assisted detection, auto-transcribe/summarize, notes template + language, neural diarization, and day tracking (activity sampling, screenshots, capture interval, retention, excluded apps).
- **Models** — every model in one tab: the transcription engine (table above), the Main LLM backend (Built-in / Apple Intelligence / Ollama / OpenAI-compatible) with its GGUF catalog and Hugging Face browser, the dedicated cotyping model, embeddings, and the Kokoro TTS voice.
- **Privacy** — screen-text retention and the "Allow external agents to read your meeting library" toggle that gates the CLI/MCP surface.
- **Advanced** — live resource monitor, hardware fit advisory, Agent CLI install.
- **Type** — enable and tune Cotyping (model, exclusions, accept granularity) and Dictation (shortcut style, paste vs. clipboard).

## FAQ

<details>
<summary>Does anything leave my Mac?</summary>

Audio stays on your Mac. Transcripts, summaries, screenshots, and workday context stay local with the built-in backend; if you approve a non-loopback Ollama or OpenAI-compatible origin, LokalBot sends the context required for requests to that server. The app also connects for model downloads, update checks, and optional Agent Mode setup. See [PRIVACY.md](PRIVACY.md).
</details>

<details>
<summary>Is it really free?</summary>

Yes. No account, no subscription, no telemetry. The full source is on GitHub, and you can build it yourself.
</details>

<details>
<summary>Which Macs are supported?</summary>

Apple Silicon Macs (M1 and later) running macOS 15.0 or newer. The on-device models lean on the Neural Engine, MLX, and Metal.
</details>

<details>
<summary>How does it record both sides?</summary>

Your microphone is one track, labeled **Me**. A Core Audio tap on the meeting app is the other, labeled **Them**. That split gives you speaker labels for free.
</details>

<details>
<summary>Can I use my own model?</summary>

Yes. Use the built-in llama.cpp runtime with any downloaded GGUF model, or point LokalBot at Ollama, any OpenAI-compatible server, or Apple Intelligence.
</details>

<details>
<summary>Is my screen being watched?</summary>

Only if you turn on screenshots — they're off by default and opt-in during onboarding. When on, they're encrypted on disk and deleted after 14 days by default. Password fields and excluded apps are never captured.
</details>

## For developers

### Agent CLI & MCP

`lokalbot-cli` (ArgumentParser, embedded in `Contents/Helpers/`) gives coding agents read-only access to the meeting library via `list` / `get` / `search` / `path`. JSON by default, `--table` for humans. Settings → Advanced → Agent CLI (or `lokalbot-cli install-skill`) symlinks the binary to `~/.local/bin/lokalbot-cli` and the bundled skill to `~/.agents/skills/lokalbot-cli/`.

The same binary is an **MCP server**: `lokalbot-cli mcp` speaks MCP over stdio and exposes `list_meetings` / `get_meeting` / `search_meetings` / `ask_library` — the last answers questions through the app's local llama-server (woken on demand under a short-lived lease), so "chat with my meetings" from Claude Desktop or Cursor still never leaves the Mac. `Scripts/build-mcpb.sh` wraps it into a one-click `dist/LokalBot.mcpb` bundle for GUI MCP clients.

The whole agent surface is **off by default**: every command requires the Privacy-pane toggle ("Allow external agents to read your meeting library"), which drops a `control/agent-access-enabled` marker under the storage root — with it off, tools return an error explaining how to enable access.

```bash
lokalbot-cli search "auth refactor"
lokalbot-cli get latest --include summary
lokalbot-cli mcp        # stdio MCP server: list/get/search/ask_library
```

<div align="center"><img src="Assets/cli-demo.svg" alt="Animated terminal session: lokalbot-cli lists meetings as a table, searches transcripts for redis and returns JSON, then prints the latest meeting summary" width="720"></div>

See [`.agents/skills/lokalbot-cli/SKILL.md`](.agents/skills/lokalbot-cli/SKILL.md).

### Headless flags

The app binary doubles as a test harness; flows that need ungranted permissions are skipped.

| Flag | Effect |
| --- | --- |
| `--process <meeting-folder> [--no-summary]` | Run the transcribe/summarize pipeline, then exit |
| `--search "<query>"` | Print FTS5 hits (and semantic hits, if enabled) |
| `--record <seconds>` | Record for N seconds (needs the Mic grant) |
| `--digest` | Generate today's day digest |
| `--shot-test` | Capture one screenshot (needs Screen Recording) |
| `--chat "<question>"` | Ask the meeting chat assistant once and print the answer |
| `--agent "<prompt>"` | Run one Agent Mode turn headlessly (tool calls auto-approved) and exit by result |
| `--cotyping-bench` | Run the cotyping quality benchmark and print a JSON report (exit 0 when every scenario passes) |

### Testing

- **Unit** (`LokalBotTests`, in-process):
  ```bash
  xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
  ```
  Pure-logic coverage — prompt sanitizers, search ranker, model fit, transcript merging, settings codecs, data migration, and the chat agent (tool-call parsing for JSON **and** native function-call forms, the ReAct loop, observation formatters).
- **UI** (`LokalBotUITests`, XCUITest): `Scripts/ui-tests.sh`. Drives a dedicated UI Test Host against a synthetic library under a tmp `LOKALBOT_STORAGE_ROOT`; `LOKALBOT_UI_TEST=1` skips every side-effectful subsystem (Core Audio polling, the trusted detector, Sparkle, screenshots), so no app permissions are needed and the suite never touches the installed production app. Eighteen tests cover meeting-list grouping, sidebar navigation, Models, Settings + permission repair, calendar gating, Chat + persisted history, detail tabs, FTS5 search → deep-link, timeline states, cotyping gating, multi-select, and both branches of the delete dialog. The first run needs the controlling terminal/IDE to hold **Automation → Xcode** and **Accessibility** grants.
- **End-to-end** (`Scripts/e2e.sh`): exercises real audio, CoreML transcription, the bundled llama-server, and SQLite via the headless flags; skips flows needing ungranted permissions.

### On-disk layout

```
~/Library/Application Support/me.dotenv.LokalBot/
├── meetings/YYYY/MM/dd-slug/   # mic.m4a, system.m4a, meta.json, transcript.{json,md}, summary.md
├── journal/YYYY-MM-DD.md       # day digests
├── activity/YYYY-MM-DD/shots/  # <epoch>.heic.enc  (AES-GCM sealed)
├── models/                     # downloaded GGUFs
├── qwen3-asr-models/           # downloaded Qwen3-ASR MLX weights
└── lokalbotv3.sqlite           # FTS5 (docs) + embeddings + activity_blocks + ocr_fts + screenshots
```

Rooted at the bundle id (not "LokalBot") so it never collides with another app's `Application Support/LokalBot` on the default case-insensitive filesystem.

<details>
<summary><strong>Project layout</strong></summary>

```
LokalBot/
├── project.yml                            # XcodeGen manifest: LokalBot + LokalBot Dev + tests + lokalbot-cli
├── Scripts/                               # fetch-llama, e2e, ui-tests, DMG + appcast release tooling
├── CLI/                                   # lokalbot-cli ArgumentParser entry + Commands/ (list/get/search/path/mcp/install-skill)
├── .agents/skills/lokalbot-cli/SKILL.md   # bundled into the app, symlinked on install
└── LokalBot/
    ├── LokalBotApp.swift   # @main: Window + MenuBarExtra + Settings scenes, headless flags
    ├── Models/             # Meeting, Transcript, AppSettings, NoteTemplate, SummaryLanguage, *Language
    ├── CLISupport/         # SessionLookup + SessionFormatter (shared with the CLI)
    ├── Services/           # detection, recorders, ProcessingPipeline, StorageManager, SearchIndex/
    │                       #   EmbeddingIndex, ActivityTracker/ScreenshotService (OCR), diarization,
    │                       #   PermissionManager, AppUpdateManager, AppLog, HuggingFace/, Chat/ (agent + tools)
    ├── Engines/            # TranscriptionEngine, TextEngine, AppleIntelligenceEngine,
    │                       #   ModelCatalog / ModelDownloadManager / LlamaServer / InferenceBroker
    ├── Support/            # prompt budgeting, download rescue, DeviceInfo/HardwareCapabilityProbe, ranker
    ├── Cotyping/           # CotypingCoordinator + AX focus tracker, CGEventTap input monitor,
    │                       #   ghost-text overlay, synthetic inserter, prompt renderer + output normalizer
    ├── Agent/              # Agent Mode: pi RPC session, Bun runtime installer, approval flow
    └── Views/              # MenuBar, MainWindow, Chat, Timeline, Search, Settings, Cotyping, Agent, Onboarding
```

</details>

### Releasing

In-place signed updates ship via [Sparkle](https://github.com/sparkle-project/Sparkle). The release runbook (notarization, appcast signing, DMG tooling) lives in [`RELEASING.md`](RELEASING.md). `AppUpdateManager` stays inert on dev builds (`LOKALBOT_DEV`) and in forks with placeholder `SUFeedURL` or `SUPublicEDKey` values.

## Status

**Done:** recording with robust device/PID handling · live meeting view (notes + rolling transcript) · transcription (8 models across 5 engines) + neural diarization · summarization (4 backends) + templates/languages · FTS5 + semantic search · synced player · Kokoro TTS · day tracking + digests · screenshots/OCR/privacy · Ask-your-day · chat assistant · inference broker (lease-managed servers, RAM budget + LRU, resource monitor) · Agent Mode (embedded pi on the local model, approval-gated) · agent CLI + MCP server + skill (opt-in) · Sparkle updates · dev/prod split · in-app model manager + Hugging Face browse · Cotyping (opt-in) · system-wide dictation (opt-in).

**Not yet built:** VLM screenshot captions (needs a multimodal model + an mmproj slot in `LlamaServer`).

<details>
<summary><strong>Known limitations</strong></summary>

- Automatic Sparkle checks are off by default to avoid background network traffic; users can run a manual check or enable scheduled checks in Settings.
- The system track falls back gracefully to mic-only (with a warning) if tap creation fails.
- AAC encoding assumes Float32 tap/mic formats — verified on M-series; if `write(from:)` throws on exotic devices, fall back to `.caf` (PCM) and transcode post-meeting.

</details>

## Contributing

Issues and pull requests are welcome. See the [issue templates](.github/ISSUE_TEMPLATE) and [pull request template](.github/PULL_REQUEST_TEMPLATE.md). Before opening a PR, please run the unit tests (above) and keep changes focused.

## License

LokalBot is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0** as published by the Free Software Foundation. See [`LICENSE`](LICENSE) for the full text.

It is distributed in the hope that it will be useful, but **without any warranty** — without even the implied warranty of merchantability or fitness for a particular purpose. Because the GPL is copyleft, any distributed derivative must also ship under the GPL with source available: the "read every line, or build it yourself" guarantee is enforced by the license, not just promised.

## Acknowledgements

Built on [llama.cpp](https://github.com/ggml-org/llama.cpp), [IBM Granite Speech](https://huggingface.co/ibm-granite), [Parakeet](https://huggingface.co/nvidia), [Whisper](https://github.com/argmaxinc/WhisperKit), and [Qwen3-ASR](https://huggingface.co/Qwen) for transcription, [FluidAudio](https://github.com/FluidInference/FluidAudio) for diarization, [Sparkle](https://github.com/sparkle-project/Sparkle) for updates, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the project manifest. Cotyping shares its loop with [Cotabby](https://cotabby.app).
