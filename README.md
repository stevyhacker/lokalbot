# LokalBot

Strictly-local meeting recorder, transcriber, day tracker, and inline AI autocomplete for macOS. It records meetings, transcribes and summarizes them, indexes everything for search, tracks how you spend your day, and — with **cotyping** — suggests text inline as you type in any app, with **no external service in the loop**. Transcription (Parakeet / Whisper / Cohere via CoreML) and summarization + cotyping (a bundled llama.cpp server with a built-in model) run entirely on-device. Ollama, an OpenAI-compatible localhost server, and Apple Intelligence are optional alternative backends.

The shipped app is **LokalBotV3** (`com.dotenv.LokalBotV3`); the Xcode project and scheme are named `LokalBot`.

## Requirements

- macOS **14.4+** (Core Audio process taps); Apple Silicon required — CoreML/Metal models and the arm64 llama.cpp build.
- Xcode 16+ with a signing team.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Build & run

```bash
cd LokalBot
xcodegen generate
open LokalBot.xcodeproj
```

Set your team under **Signing & Capabilities**, pick a scheme, and Run:

- **LokalBot** — production (`com.dotenv.LokalBotV3`), Sparkle auto-update compiled in.
- **LokalBot Dev** — `com.dotenv.LokalBotV3.dev`, `LOKALBOTV3_DEV` flag, Sparkle compiled out. A distinct bundle id means its own Mic / Screen Recording / Accessibility TCC grants, so running from Xcode never disturbs the released app.

The first build runs `Scripts/fetch-llama.sh` (a pre-build phase) which vendors the pinned llama.cpp server (`b9587` — server + dylibs, ~10 MB) and the built-in model (Qwen3.5 0.8B Q4_K_M, ~0.5 GB) into `Vendor/`, copied into the app bundle. On first recording macOS prompts for **Microphone** and **System Audio Recording**; transcription and screenshot models download from Hugging Face on first use.

## Features

### Recording & meeting detection
- **Detection:** polls for known meeting apps (Zoom, Teams, Slack, Webex, FaceTime) plus mic-in-use, backed by event-driven signals — Core Audio property listeners on the default input (with device-change re-arm), `NSWorkspace` launch/quit, and an `AudioSourceMonitor` that treats *silent → producing-output* transitions as meeting candidates (catches muted calls and tabs opened before the mic). **Browser meetings** (Google Meet, Jitsi, Whereby) are detected from the focused-window title when Accessibility is granted; the system-audio tap captures the browser. Auto-start is configurable (auto / ask / manual); auto-stop debounces (default 60 s, configurable).
- **Two synchronized tracks:** `mic.m4a` (AVAudioEngine) = **Me**, `system.m4a` (Core Audio process tap on the meeting app's PID → aggregate device → AAC) = **Them** — free diarization. The engine re-installs its tap on `AVAudioEngineConfigurationChange` (AirPods/USB switches no longer truncate the recording), drains the converter on stop (keeps trailing audio), stops cleanly if the captured app exits, and encodes AAC off the real-time IOProc thread.
- **UI:** menu-bar item (record state, start/stop, recent meetings, pause/resume) plus a main window (meeting list, Show in Finder, in-app playback).

### Transcription & speakers
- **Engines** (Settings → Transcription; CoreML, in-process, Neural Engine):
  - **Parakeet TDT 0.6B v3** — 25 languages, ~190× realtime — *default*
  - **Parakeet TDT 0.6B v2** — English only, slightly higher recall
  - **Whisper large-v3 turbo** (WhisperKit, ~1.6 GB) — 99 languages, word timestamps
  - **Cohere Transcribe** (~1.7 GB) — 23 languages incl. CJK/Arabic (one segment per track, no per-sentence timestamps yet)

  Models auto-download from Hugging Face on first use (~600 MB for Parakeet) and are cached.
- **Speaker attribution:** mic track = **Me**, system track = **Them**, merged by timestamp into `transcript.json` + `transcript.md`.
- **Neural diarization (opt-in):** Settings → "Split Them by speaker" runs FluidAudio's offline pyannote-community-1 pipeline on `system.m4a` after transcription and relabels segments "Them 1 / Them 2 / …" (tuned: threshold 0.70, step ratio 0.15, min segment 0.3 s). First run downloads ~100 MB of CoreML models.

### Summarization & notes
- **Backends** (Settings → Summarization, all HTTP-to-localhost only): **Built-in** (bundled llama.cpp — no setup, *default*) · **Apple Intelligence** (FoundationModels, macOS 26+, gated so the app still builds/launches on 14.4) · **Ollama** · **any OpenAI-compatible server** (LM Studio, vllm-mlx, …).
- **Output:** `summary.md` with TL;DR / Key points / Decisions / Action items / Open questions. Map-reduce for long meetings; `<think>` reasoning blocks are stripped.
- **Templates & language:** pick a notes template (Meeting / Lecture / Study guide / Podcast / Free-form) and a summary language (auto-detected via `NLLanguageRecognizer`, with Simplified / Traditional / Cantonese handling). Prompt budgeting (`TokenCountEstimator`, `PromptContextSanitizer`, `PromptSectionBudget`) keeps prompts within the model's context.
- **Pipeline:** runs automatically when a recording stops (configurable); serial queue with per-meeting status in the UI, plus a Process menu for manual / re-runs.

### Built-in LLM runtime
- `LlamaServer` copies the vendored `llama-server` out of Resources into Application Support on first run (never executes from inside the bundle), spawns it (`-ngl 99 --jinja`, port 17872), health-checks `/health`, restarts on model switch, and terminates on quit.
- **Model catalog** (Settings → Summarization) — download / cancel / delete with progress, radio-select the active model:
  Qwen3.5 0.8B (built-in, ~0.5 GB) · Qwen3.5 2B (1.3 GB) · Gemma 4 E4B (5.0 GB) · LFM2.5 8B MoE (5.2 GB) · Qwen3.6 35B MoE (17.7 GB). Qwen "thinking" is disabled for summaries via `chat_template_kwargs`.
- **Browse Hugging Face** in-app: search GGUF repos, list `.gguf` files, download — resilient (synchronous temp-file rescue, outcome classification, GGUF magic-byte validation). `HardwareCapabilityProbe` surfaces a per-model fit advisory under Settings → System.

### Search & player
- **Index:** SQLite + FTS5 (`lokalbotv3.sqlite` — system SQLite, no dependency) over titles, transcript segments, summaries, and OCR'd screen text. Segment rows carry their audio timestamp; incremental re-index by file mtime on launch and after each pipeline run.
- **Semantic search:** transcript/summary chunks embedded with nomic-embed-text v1.5 (~146 MB GGUF, auto-downloaded) on a second llama-server instance (port 17873, `--embeddings --pooling mean`); vectors live in SQLite and queries are brute-force cosine — instant at personal scale, zero extra dependency. Search → All adds a "Related (semantic)" section for meaning-matches keywords miss; toggle in Settings.
- **UI:** sidebar Meetings | Chat | Timeline | Cotyping | Search; debounced search-as-you-type (last term prefix-matched), All / Transcripts / Summaries / Screen scopes, «highlighted» snippets; clicking a transcript hit opens the meeting and plays from that timestamp.
- **Player:** mic + system tracks play in sync (shared device-time anchor); seek bar; click any transcript line to jump the audio there; the currently-playing segment is highlighted.

### Chat assistant
- **Chat with your meetings:** the **Chat** sidebar section is a conversational assistant over your library — ask what was decided, find action items, or search transcripts in natural language. A small ReAct agent (`ChatAgent`) reuses the **same** local `TextEngine` as summaries and calls tools to ground every answer; nothing leaves the Mac.
- **Tools (pi-agent style, mirroring the CLI):** `search_meetings` (FTS5 keyword + optional semantic search over transcripts/summaries), `list_meetings` (filter by title), and `get_meeting` (read a meeting's summary or transcript). The agent picks a tool, reads the observation, then answers — citing meeting titles and dates, and saying so plainly when nothing matches.
- **Robust protocol:** tools are advertised in the system prompt with the recent-meeting list as ambient context; a tool call is parsed from either a JSON object **or** a model's native `name(arg=…)` function-call form (the bundled 0.8B Qwen emits the latter), with a tolerant fallback to a plain answer so a sloppy reply never hard-fails.
- **Reuses the configured backend:** built-in llama-server by default, or Ollama / OpenAI-compatible / Apple Intelligence — the same Settings → Summarization choice.

### Day tracking
- **Sampler:** frontmost app + focused-window title (Accessibility; degrades to app-name-only) every 5 s, idle-aware (3 min), minimum 5 s block, pause/resume from the menu bar. Stored in `activity_blocks` (same SQLite db).
- **Timeline:** per-day colored block bar with hover details, time-by-app totals with %, and day navigation. An **Ask your day** box answers free-form questions from the day's activity blocks + OCR'd screen text + meetings via the local LLM.
- **Day digest:** "Generate digest" runs the configured LLM over the day's blocks + meetings + OCR'd text → `journal/YYYY-MM-DD.md` (What I worked on / Meetings / Time allocation).

### Cotyping (inline AI autocomplete)
- **Ghost text everywhere:** as you type in almost any macOS text field, a gray suggestion appears next to the cursor; press **Tab** to accept (a word at a time, or the whole thing — Settings → Cotyping), or keep typing / press **Esc** to dismiss. Built on the same loop as [Cotabby](https://cotabby.app): an Accessibility poll resolves the focused field + caret, a `CGEventTap` watches keystrokes (and swallows the accept key only while a suggestion shows), a borderless click-through `NSPanel` renders the ghost at the caret, and accepted text is inserted as synthetic Unicode keystrokes.
- **Reuses the local LLM:** suggestions come from the **same** backend as summaries (built-in llama-server by default, or Ollama / OpenAI-compatible / Apple Intelligence) through a low-latency raw `/v1/completions` call. The prompt treats the model as a pure text-continuer (optional name/style preface + the caret prefix last); raw output is cleaned by a shared normalizer (strips chat/`<think>` scaffolding, prompt echoes, and trailing-text duplication; collapses to one line). Nothing leaves the Mac.
- **Opt-in & private:** off by default; needs **Accessibility** + **Input Monitoring**. Never reads password/secure fields; honors a per-user app exclusion list (preseeded with password managers and terminals).
- **In-app preview:** the **Cotyping** tab has a live playground that runs the real pipeline on text typed *inside LokalBot* — try it with zero system permissions. Quick-toggle from the menu bar.

### Screenshots, OCR & privacy
- **Capture:** ScreenCaptureKit screenshot of the main display every N minutes (default 3, Settings slider), downscaled to ≤1500 px, HEIC. Skipped when idle (3 min), paused, locked, or when an excluded app is frontmost. Requires the Screen Recording permission.
- **OCR:** Vision (`VNRecognizeTextRequest`, on-device) runs immediately; text goes into `ocr_fts` (searchable under Search → Screen) and feeds day digests and Ask-your-day.
- **Encryption & retention:** each screenshot is AES-GCM sealed with a per-install key in the macOS Keychain; pixels auto-delete after N days (default 14, Settings stepper) while OCR text is kept. The timeline shows a decrypted thumbnail filmstrip.
- **Exclusions:** comma-separated app list (preseeded with password managers); excluded time logs as "Private" — no titles, no screenshots.

### Agent CLI
- `lokalbot-cli` (ArgumentParser, embedded in `Contents/Helpers/`) gives coding agents read-only access to the meeting library via `list` / `get` / `search` / `path`. JSON by default, `--table` for humans. Settings → Agent CLI symlinks the binary to `~/.local/bin/lokalbot-cli` and the bundled skill to `~/.agents/skills/lokalbot-cli/`. See `.agents/skills/lokalbot-cli/SKILL.md`.

### Auto-update
- In-place signed updates via [Sparkle](https://github.com/sparkle-project/Sparkle): a silent background check on launch plus manual **Settings → Updates → Check for Updates…**, with the auto-check toggle bound to Sparkle's own preference. `AppUpdateManager` keeps the updater inert on dev builds (`LOKALBOTV3_DEV`) and until `SUFeedURL` + `SUPublicEDKey` are real (see `RELEASING.md`), so a fresh clone never self-updates.

## Headless flags

The app binary doubles as a test harness; flows that need ungranted TCC permissions are skipped:

| Flag | Effect |
| --- | --- |
| `--process <meeting-folder> [--no-summary]` | Run the transcribe/summarize pipeline, then exit |
| `--search "<query>"` | Print FTS5 hits (and semantic hits, if enabled) |
| `--record <seconds>` | Record for N seconds (needs the Mic grant) |
| `--digest` | Generate today's day digest |
| `--shot-test` | Capture one screenshot (needs Screen Recording) |
| `--chat "<question>"` | Ask the meeting chat assistant once (tool-calling Q&A) and print the answer |

## Testing

- **Unit** (`LokalBotTests`, in-process): `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test`. Pure-logic coverage — prompt sanitizers, search ranker, model fit, transcript merging, settings codecs, data migration, and the chat agent (tool-call parsing for JSON **and** native function-call forms, the ReAct loop, observation formatters).
- **UI** (`LokalBotUITests`, XCUITest): `Scripts/ui-tests.sh`. Drives the real `LokalBotV3.app` against a synthetic library planted under a tmp `LOKALBOTV3_STORAGE_ROOT`; `LOKALBOTV3_UI_TEST=1` makes the app skip every side-effectful subsystem (Core Audio polling, the accessibility-trusted detector, Sparkle, screenshots), so no app TCC grants are needed. Eight tests cover meeting-list grouping (+ Record button), sidebar navigation, the Chat section (render + input acceptance), detail tabs (Summary/Transcript), FTS5 search → deep-link, multi-select state, and both branches of the delete dialog (cancel keeps files; confirm removes rows **and** on-disk folders). The first run needs the controlling terminal/IDE to hold **Automation → Xcode** and **Accessibility** grants, or XCUITest fails with "Timed out while enabling automation mode."
- **End-to-end** (`Scripts/e2e.sh`): exercises real audio, CoreML transcription, the bundled llama-server, and SQLite via the headless flags; skips flows needing ungranted permissions, so it's useful both pre- and post-grant.

## On-disk layout

```
~/Library/Application Support/com.dotenv.LokalBotV3/
├── meetings/YYYY/MM/dd-slug/   # mic.m4a, system.m4a, meta.json, transcript.{json,md}, summary.md
├── journal/YYYY-MM-DD.md       # day digests
├── activity/YYYY-MM-DD/shots/  # <epoch>.heic.enc  (AES-GCM sealed)
├── models/                     # downloaded GGUFs
└── lokalbotv3.sqlite           # FTS5 (docs) + embeddings + activity_blocks + ocr_fts + screenshots
```

Rooted at the bundle id — not "LokalBotV3" — so it never collides with another app's `Application Support/LokalBotV3` on the default case-insensitive filesystem.

## Project layout

```
LokalBot/
├── project.yml                            # XcodeGen manifest: LokalBot + LokalBot Dev + tests + lokalbot-cli
├── Scripts/                               # fetch-llama, e2e, ui-tests, DMG + appcast release tooling
├── CLI/                                   # lokalbot-cli ArgumentParser entry + Commands/ (list/get/search/path)
├── .agents/skills/lokalbot-cli/SKILL.md   # bundled into the app, symlinked on install
└── LokalBot/
    ├── LokalBotApp.swift   # @main: Window + MenuBarExtra + Settings scenes, headless flags
    ├── Models/             # Meeting, Transcript, AppSettings, NoteTemplate, SummaryLanguage, *Language
    ├── CLISupport/         # SessionLookup + SessionFormatter (shared with the CLI)
    ├── Services/           # detection, recorders, ProcessingPipeline, StorageManager, SearchIndex/
    │                       #   EmbeddingIndex, ActivityTracker/ScreenshotService (OCR), diarization,
    │                       #   PermissionManager, AppUpdateManager, AppLog/FileLogHandler, HuggingFace/, Chat/ (agent + tools)
    ├── Engines/            # TranscriptionEngine, TextEngine, AppleIntelligenceEngine,
    │                       #   ModelCatalog / ModelDownloadManager / LlamaServer
    ├── Support/            # prompt budgeting, download rescue, DeviceInfo/HardwareCapabilityProbe, ranker
    ├── Cotyping/           # CotypingCoordinator + AX focus tracker, CGEventTap input monitor,
    │                       #   ghost-text overlay, synthetic inserter, prompt renderer + output
    │                       #   normalizer, and the HTTP completion engine (reuses TextEngine)
    └── Views/              # MenuBar, MainWindow, Chat, Timeline, Search, Settings, Cotyping, Onboarding, banners
```

## Status

**Done:** recording + robust device/PID handling, transcription (4 engines) + opt-in neural diarization, summarization (4 backends) + templates/languages, FTS5 + semantic search, synced player, day tracking + digests, screenshots/OCR/privacy, Ask-your-day, chat assistant (tool-calling Q&A over meetings, reuses the LLM), agent CLI, Sparkle updates, dev/prod split, in-app model manager + Hugging Face browse, cotyping (inline AI autocomplete reusing the LLM — opt-in).

**Not yet built:** VLM screenshot captions (needs a multimodal model + an mmproj slot in `LlamaServer`).

## Known limitations

- Sparkle ships placeholder `SUFeedURL` (`OWNER/REPO`) + `SUPublicEDKey` — generate a key and set the appcast URL before the first release (see `RELEASING.md`); until then `AppUpdateManager` stays inert (no accidental self-update).
- The system track falls back gracefully to mic-only (with a warning) if tap creation fails.
- AAC encoding assumes Float32 tap/mic formats — verified on M-series; if `write(from:)` throws on exotic devices, fall back to `.caf` (PCM) and transcode post-meeting.
