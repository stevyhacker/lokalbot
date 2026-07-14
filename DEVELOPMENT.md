# LokalBot — technical deep dive

Everything the [README](README.md) summarizes, in full detail: subsystem internals, configuration, headless flags, testing, and the on-disk layout. For the contributor-workflow ground rules (XcodeGen, schemes, pinned dependencies), also see [CLAUDE.md](CLAUDE.md); for the release runbook, [RELEASING.md](RELEASING.md).

## Recording & meeting detection

- **Detection:** polls for known meeting apps (Zoom, Teams, Slack, Webex, FaceTime) plus mic-in-use, backed by event-driven signals — Core Audio property listeners on the default input (with device-change re-arm), `NSWorkspace` launch/quit, and an `AudioSourceMonitor` that treats *silent → producing-output* transitions as meeting candidates (catches muted calls and tabs opened before the mic). **Browser meetings** (Google Meet, Jitsi, Whereby) are detected from the focused-window title when Accessibility is granted; the system-audio tap captures the browser. Auto-start is configurable (auto / ask / manual); auto-stop debounces (default 60 s, configurable).
- **Two synchronized tracks:** `mic.m4a` (AVAudioEngine) = **Me**, `system.m4a` (Core Audio process tap on the meeting app's PID → aggregate device → AAC) = **Them** — free diarization. The engine re-installs its tap on `AVAudioEngineConfigurationChange` (AirPods/USB switches no longer truncate the recording), drains the converter on stop (keeps trailing audio), stops cleanly if the captured app exits, and encodes AAC off the real-time IOProc thread.
- **UI:** menu-bar item (record state, start/stop, recent meetings, pause/resume) plus a main window (meeting list, Show in Finder, in-app playback). While a recording runs, the meeting opens in a **live view**: a quick-notes pad (notes land in the finished meeting) and an opt-in rolling live transcript.

## Transcription & speakers

Engines (Settings → Models; CoreML/MLX, in-process, Neural Engine/Metal):

| Engine | Coverage | Notes |
| --- | --- | --- |
| **IBM Granite Speech 4.1** | high-accuracy local ASR | **recommended** |
| **Parakeet TDT 0.6B v3** | 25 languages, up to ~190× realtime in local benchmarks | fastest local option |
| **Parakeet TDT 0.6B v2** | English only | slightly higher recall |
| **Qwen3-ASR 1.7B** (MLX, ~3.2 GB) | 52 languages/dialects | best Qwen accuracy tier for harder recordings |
| **Qwen3-ASR 0.6B** (MLX, ~0.7 GB) | global coverage | compact tier |
| **Whisper large-v3 turbo** (WhisperKit, ~1.6 GB) | 99 languages | word timestamps; wide-language fallback |
| **SenseVoice / GigaAM** (ONNX) | CJK/Cantonese/English, Russian | specialist coverage |
| **Cohere Transcribe** (2B) | 14 languages | legacy — hidden unless already installed (no language detection, timestamps, or diarization) |

Models auto-download on first use (Hugging Face; the ONNX specialists fetch sherpa-onnx archives from GitHub) and are cached under Application Support.

- **Speaker attribution:** mic track = **Me**, system track = **Them**, merged by timestamp into `transcript.json` + `transcript.md`. When calendar detection matches the meeting to an event, the remote speaker is named from the invite's attendees instead of "Them".
- **Neural diarization:** Settings → Recording → "Split 'Them' by speaker" runs FluidAudio's offline pyannote-community-1 pipeline on `system.m4a` after transcription and relabels segments "Them 1 / Them 2 / …" (threshold 0.70, step ratio 0.15, min segment 0.3 s). Enabled by default; first run downloads ~100 MB of CoreML models.

## Summarization & notes

- **Backends** (Settings → Models): **Built-in** (included localhost llama.cpp runtime; choose/download a GGUF model) · **Apple Intelligence** (FoundationModels, macOS 26+, gated so the app still builds/launches on 15.0) · **Ollama** · **any OpenAI-compatible server** (LM Studio, vllm-mlx, …). Non-loopback endpoints require explicit origin approval before context is sent.
- **Output:** `summary.md` with TL;DR / Key points / Decisions / Action items / Open questions. Map-reduce for long meetings; `<think>` reasoning blocks are stripped.
- **Templates & language:** pick a notes template (Meeting / Lecture / Study guide / Podcast / Free-form) and a summary language (auto-detected via `NLLanguageRecognizer`, with Simplified / Traditional / Cantonese handling). Prompt budgeting (`TokenCountEstimator`, `PromptContextSanitizer`, `PromptSectionBudget`) keeps prompts within the model's context.
- **Pipeline:** runs automatically when a recording stops (configurable); serial queue with per-meeting status in the UI, plus a Process menu for manual re-runs.

## Built-in LLM runtime — llama.cpp & model catalog

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
| Qwen 3.6 · 35B-A3B | 17.7 GB | recommended summaries on 32 GB+ Macs |
| Qwen 3.6 · 27B | ~16.8 GB | maximum-quality dense summaries |
| Gemma 4 · 12B | ~7.5 GB | multimodal-family summaries |

- **Browse Hugging Face** in-app: search GGUF repos, list `.gguf` files, download — resilient (synchronous temp-file rescue, outcome classification, GGUF magic-byte validation). `HardwareCapabilityProbe` surfaces a per-model fit advisory under Settings → Models.

## Search & player

- **Index:** SQLite + FTS5 (`lokalbotv3.sqlite` — system SQLite, no dependency) over titles, transcript segments, summaries, and OCR'd screen text. Segment rows carry their audio timestamp; incremental re-index by file mtime on launch and after each pipeline run.
- **Semantic search:** transcript/summary chunks and retained screen OCR are embedded with Qwen3-Embedding 0.6B GGUF on a second llama-server instance (port 17873, `--embeddings --pooling mean`); vectors live in SQLite with a model-version marker and queries are brute-force cosine — instant at personal scale, zero extra dependency. Screen results fuse FTS and semantic ranks with deterministic reciprocal-rank fusion while preserving the exact snapshot id. Qwen3-VL-Embedding 2B remains future work for direct image-vector retrieval.
- **UI:** sidebar Timeline | Meetings | Ask | Type | Agent | Settings; search lives in **Ask** — debounced search-as-you-type (last term prefix-matched), All / Transcripts / Summaries / Screen facets, «highlighted» snippets; clicking a transcript hit opens the meeting and plays from that timestamp.
- **Player:** mic + system tracks play in sync (shared device-time anchor); seek bar; click any transcript line to jump the audio there; the currently-playing segment is highlighted.

## Ask assistant — conversational Q&A over your library

- **Chat with your meetings:** pressing ↵ in the **Ask** section escalates your query to a conversational assistant over your library — ask what was decided, find action items, or search transcripts in natural language. A small ReAct agent (`ChatAgent`) reuses the selected `TextEngine` and calls tools to ground every answer. With the built-in default it stays on the Mac; an approved remote backend receives the prompt context needed to answer.
- **Tools (pi-agent style, mirroring the CLI):** `search_meetings` (FTS5 keyword + optional semantic search), `list_meetings` (filter by title), and `get_meeting` (read a meeting's summary or transcript). The agent picks a tool, reads the observation, then answers — citing meeting titles and dates, and saying so plainly when nothing matches.
- **Robust protocol:** tools are advertised in the system prompt with the recent-meeting list as ambient context; a tool call is parsed from a JSON object **or** a model's native `name(arg=…)` function-call form (smaller Qwen models emit the latter), with a tolerant fallback to a plain answer so a sloppy reply never hard-fails.
- **Reuses the configured backend:** built-in llama-server by default, or Ollama / OpenAI-compatible / Apple Intelligence — the same Settings → Models choice.

## Day tracking — timeline, digests, "ask your day"

- **Opt-in:** day tracking is off by default. A dedicated onboarding step (or Settings → Recording → Day tracking) turns on activity sampling and, separately, screenshots — finishing setup never silently enables either.
- **Sampler:** frontmost app + focused-window title (Accessibility; degrades to app-name-only) every 5 s, idle-aware (3 min), minimum 5 s block, pause/resume from the menu bar. Stored in `activity_blocks` (same SQLite db).
- **Timeline:** per-day colored block bar plus a visual Rewind rail over perceptually grouped captures. Users can scrub, hover, step, play, open an exact frame, save/note a moment, pin it into Ask, or permanently delete a selected time range. An **Ask your day** action answers from activity blocks + OCR'd screen text + meetings via the local LLM.
- **Day digest:** "Generate digest" runs the configured LLM over the day's blocks + meetings + OCR'd text → `journal/YYYY-MM-DD.md` (What I worked on / Meetings / Time allocation).

## Cotyping — inline AI autocomplete

- **Ghost text everywhere:** as you type in almost any macOS text field, a gray suggestion appears next to the cursor; press **Tab** to accept (a word at a time, or the whole thing — Type → Cotyping), or keep typing / press **Esc** to dismiss. Built on the same loop as [Cotabby](https://cotabby.app): an Accessibility poll resolves the focused field + caret, a `CGEventTap` watches keystrokes (and swallows the accept key only while a suggestion shows), a borderless click-through `NSPanel` renders the ghost at the caret, and accepted text is inserted as synthetic Unicode keystrokes.
- **Its own dedicated on-device model:** cotyping decodes a dedicated model (recommended **Gemma 4 · E4B**) **in-process via libllama** for low latency, with the localhost `llama-server` as the fallback. The prompt treats the model as a pure text-continuer; raw output is cleaned by a shared normalizer (strips chat/`<think>` scaffolding, prompt echoes, and trailing-text duplication; collapses to one line).
- **Opt-in & private:** off by default; needs **Accessibility** + **Input Monitoring**. Never reads password/secure fields; honors a per-user app exclusion list (preseeded with password managers and terminals).
- **In-app preview:** the **Type** section has a live playground that runs the real pipeline on text typed *inside LokalBot* — try it with zero system permissions. Quick-toggle from the menu bar.

## Dictation — system-wide voice typing

- **Hold ⌥ Space and talk** (or switch to toggle mode): a floating pill shows recording state and a live transcript while you speak; release, and the text is pasted into the focused app — or copied to the clipboard instead (Type → Dictation).
- **Your ASR, prewarmed:** dictation reuses the transcription engine and language you picked under Models (Granite, Parakeet, Whisper, Qwen3-ASR, …) and prewarms it when the shortcut is armed, so short dictations start instantly.
- **Considerate capture:** playing media (Spotify, Music, browsers, VLC, …) is paused before recording starts; audio goes to a local PCM scratch file and is deleted right after transcription.
- **Opt-in & private:** off by default; needs the Microphone grant plus Input Monitoring for the global shortcut. Audio, transcription, and paste all happen on-device.

## Agent Mode — an embedded coding agent on your selected Main LLM

- **A coding agent in the sidebar:** the **Agent** section embeds the pi coding agent, preconnected to the same local Main LLM through an OpenAI-compatible shim — a coding agent running on your own GGUF (or whichever backend you configured). Sessions run in tabs, and an active session holds an inference lease so the model stays loaded while you work.
- **Pi's own network behavior is disabled:** pi runs with `--offline`, version checks and crash reporting disabled. Enabling Agent Mode downloads its runtime once — a checksum-verified Bun release from GitHub plus the pi package from npm, pinned by a lockfile bundled with LokalBot. LLM requests stay local with the built-in backend; an approved remote Ollama or OpenAI-compatible endpoint receives agent context when selected.
- **You approve sensitive access:** `write` / `edit` tool calls pause behind native approval cards unless you opt into file changes for the session. Every shell command and every read outside the selected workspace requires a fresh one-time approval. Approved shell commands run with your macOS user permissions and may access files or the network.
- **Headless:** `LokalBot --agent "<prompt>"` runs one agent turn from the terminal (see Headless flags). It auto-approves file changes but safely declines shell and external-read requests because no person is present to review them.

## Screenshots, OCR & privacy

- **Capture:** off by default, enabled only by the onboarding day-memory step or Settings → Recording → Day tracking. When on, ScreenCaptureKit captures the main display on app/window changes with a 20-second cooldown, plus an idle-active fallback at the configured interval; byte-identical automatic frames are skipped, while a separate 64-bit perceptual dHash groups visually similar retained frames without discarding changed OCR evidence (manual capture bypasses exact dedup). Images are downscaled to ≤1500 px and encoded as HEIC. Capture is also skipped when idle (3 min), paused, locked, or when an excluded app is frontmost. It is display-level and cannot redact a password field inside an otherwise allowed app.
- **OCR:** Vision (`VNRecognizeTextRequest`, on-device) runs immediately; text goes into `ocr_fts` (searchable under Ask → Screen) and feeds day digests and Ask-your-day.
- **Encryption & retention:** each screenshot is AES-GCM sealed with a per-install key in the macOS Keychain; pixels auto-delete after N days (default 14, Settings stepper), and OCR text follows the same retention unless you opt into keeping it forever (Settings → Privacy). Saved moments retain their encrypted pixels, OCR, and semantic vector until unsaved or explicitly deleted. The timeline shows a decrypted thumbnail filmstrip.
- **Exclusions:** comma-separated app list (preseeded with password managers); excluded time logs as "Private" — no titles, no screenshots.

## Configuration

Everything lives in **Settings** — five tabs with a search box that finds any setting — plus per-feature controls in the **Type** section:

- **General** — launch at login, menu-bar-only mode, the opt-in `⌃⇧Space` Quick Recall shortcut, permission status + repair, storage location, update checks.
- **Recording** — auto-record behavior, calendar-assisted detection, auto-transcribe/summarize, notes template + language, neural diarization, day tracking, and scheduled Markdown/Obsidian/Logseq daily-memory export.
- **Models** — every model in one tab: the transcription engine (table above), the Main LLM backend (Built-in / Apple Intelligence / Ollama / OpenAI-compatible) with its GGUF catalog and Hugging Face browser, the dedicated cotyping model, embeddings, and the Kokoro TTS voice.
- **Privacy** — screen-text retention plus independent meeting-library and screen-memory MCP permission markers.
- **Advanced** — live resource monitor, hardware fit advisory, Agent CLI install.
- **Type** — enable and tune Cotyping (model, exclusions, accept granularity) and Dictation (shortcut style, paste vs. clipboard).

## Agent CLI & MCP

`lokalbot-cli` (ArgumentParser, embedded in `Contents/Helpers/`) gives coding agents read-only access to the meeting library via `list` / `get` / `search` / `path`. JSON by default, `--table` for humans. Settings → Advanced → Agent CLI (or `lokalbot-cli install-skill`) symlinks the binary to `~/.local/bin/lokalbot-cli` and the bundled skill to `~/.agents/skills/lokalbot-cli/`.

The same binary is an **MCP server**: `lokalbot-cli mcp` speaks MCP over stdio. Meeting tools are `list_meetings` / `get_meeting` / `search_meetings` / `ask_library`. Independently gated screen tools are `search_screen` / `get_timeline` / `get_recent_activity` / `get_app_usage` / `get_screenshot_detail`; they use a query-only SQLite connection and return OCR/metadata, never decrypted pixels or file paths. LokalBot does not upload library content, but an external MCP client may transmit tool inputs and results under its own privacy terms.

Both agent surfaces are **off by default**. Meeting tools require `control/agent-access-enabled`; screen-memory tools require the separate `control/screen-memory-access-enabled` marker. Neither marker grants the other capability.

See [`.agents/skills/lokalbot-cli/SKILL.md`](.agents/skills/lokalbot-cli/SKILL.md).

## Headless flags

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

## Testing

- **Unit** (`LokalBotTests`, in-process):
  ```bash
  xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
  ```
  Pure-logic coverage — prompt sanitizers, search ranker, model fit, transcript merging, settings codecs, data migration, and the chat agent (tool-call parsing for JSON **and** native function-call forms, the ReAct loop, observation formatters).
- **UI** (`LokalBotUITests`, XCUITest): `Scripts/ui-tests.sh`. Drives a dedicated UI Test Host against a synthetic library under a tmp `LOKALBOT_STORAGE_ROOT`; `LOKALBOT_UI_TEST=1` skips every side-effectful subsystem (Core Audio polling, the trusted detector, Sparkle, screenshots), so no app permissions are needed and the suite never touches the installed production app. Eighteen tests cover meeting-list grouping, sidebar navigation, Models, Settings + permission repair, calendar gating, Chat + persisted history, detail tabs, FTS5 search → deep-link, timeline states, cotyping gating, multi-select, and both branches of the delete dialog. The first run needs the controlling terminal/IDE to hold **Automation → Xcode** and **Accessibility** grants.
- **End-to-end** (`Scripts/e2e.sh`): exercises real audio, CoreML transcription, the bundled llama-server, and SQLite via the headless flags; skips flows needing ungranted permissions.

## On-disk layout

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

## Project layout

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

## Releasing

In-place signed updates ship via [Sparkle](https://github.com/sparkle-project/Sparkle). The release runbook (notarization, appcast signing, DMG tooling) lives in [`RELEASING.md`](RELEASING.md). `AppUpdateManager` stays inert on dev builds (`LOKALBOT_DEV`) and in forks with placeholder `SUFeedURL` or `SUPublicEDKey` values.

## Status

**Done:** recording with robust device/PID handling · live meeting view (notes + rolling transcript) · transcription (8 models across 5 engines) + neural diarization · summarization (4 backends) + templates/languages · FTS5 + semantic meeting/screen search · synced player · Kokoro TTS · day tracking + digests · encrypted visual Rewind + exact screen citations + saved moments · Quick Recall · scheduled Markdown/Obsidian/Logseq export · Ask-your-day · chat assistant · inference broker · Agent Mode · separately gated meeting/screen MCP tools · Sparkle updates · dev/prod split · in-app model manager + Hugging Face browse · Cotyping (opt-in) · system-wide dictation (opt-in).

**Not yet built:** VLM screenshot captions (needs a multimodal model + an mmproj slot in `LlamaServer`).
