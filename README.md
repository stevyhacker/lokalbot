# Botina — M1 recorder · M2 transcribe & summarize · M3 search · M4 day tracking

Strictly-local meeting recorder and day tracker for macOS. **Zero external dependencies**: transcription (Parakeet/CoreML) and summarization (bundled llama.cpp server + built-in model) both run in/with the app. Ollama / OpenAI-compatible servers remain optional backends for power users.

## Requirements

- macOS **14.4+** (Core Audio process taps), Apple Silicon recommended
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Setup

```bash
cd LokalBot
xcodegen generate
open LokalBot.xcodeproj
```

In Xcode: select your team under Signing & Capabilities, then Run. On first recording, macOS will prompt for **Microphone** and **System Audio Recording** permission.

## What works

**M1 — recording**
- **Detection:** polls for known meeting apps (Zoom, Teams, Slack, Webex, FaceTime) + mic-in-use; auto-start per settings (auto / ask / manual), auto-stop with 60 s debounce.
- **Recording:** two synchronized tracks — `mic.m4a` (AVAudioEngine) and `system.m4a` (Core Audio process tap on the meeting app's PID → aggregate device → AAC). Mic = "Me", system = "Them" (free diarization).
- **Storage:** `~/Library/Application Support/com.dotenv.Botina/meetings/YYYY/MM/dd-slug/` with `meta.json` per meeting. (Bundle-id folder, not "Botina" — avoids colliding with any other app's `Application Support/Botina`.)
- **UI:** menu bar item (record state, start/stop, recent meetings) + main window (meeting list, Show in Finder, playback via QuickTime).

**M2 — transcription & summarization**
- **Transcription:** Parakeet TDT 0.6B via [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML, in-process, Neural Engine, ~190× realtime. v3 (25 languages, default) or v2 (English, higher recall). Model (~600 MB) auto-downloads from Hugging Face on first use.
- **Speaker attribution:** mic track = **Me**, system track = **Them**; merged by timestamp into `transcript.json` + `transcript.md`.
- **Summarization:** Ollama (`/api/chat`) or any OpenAI-compatible localhost server (LM Studio, vllm-mlx…). Map-reduce for long meetings. Output is `summary.md` with TL;DR / Key points / Decisions / Action items / Open questions. Strips `<think>` blocks from reasoning models.
- **Pipeline:** runs automatically when a recording stops (configurable); serial queue with per-meeting status in the UI; Process menu for manual / re-runs.
- **UI:** Summary + Transcript tabs in the meeting detail; Settings → Transcription/Summarization with Ollama auto-detection, model picker, and a "Test generation" button.
- **Headless mode:** `Botina --process <meeting-folder> [--no-summary]` runs the pipeline without the UI (used for end-to-end testing).

**M3 — search & player**
- **Index:** SQLite + FTS5 (`botina.sqlite` in the storage root, system SQLite — no dependency) over titles, transcript segments, and summaries. Segment-level rows carry their audio timestamp. Incremental re-index by file mtime, triggered on launch and after each pipeline run.
- **Search UI:** sidebar Meetings | Search; debounced search-as-you-type (last term prefix-matched), All/Transcripts/Summaries scope, «highlighted» snippets; clicking a transcript hit opens the meeting and plays from that timestamp.
- **Player:** mic + system tracks play in sync (shared device-time anchor); seek bar; click any transcript line to jump the audio there; the currently-playing segment is highlighted.
- **Headless:** `Botina --search "<query>"` prints index hits (test hook).

**M3.5 — built-in LLM (no Ollama/LM Studio required)**
- `Scripts/fetch-llama.sh` (Xcode pre-build phase) vendors the pinned llama.cpp release (`b9587`, llama-server + dylibs, ~10 MB) and the default model (Qwen3 0.6B Q8_0, 0.64 GB) into `Vendor/`, which is copied into the app bundle. First build downloads once; afterwards cached.
- `LlamaServer` actor copies the server out of Resources into Application Support on first run, spawns it (`-ngl 99 --jinja`, port 17872), health-checks, restarts on model switch, terminates on app quit.
- **Model catalog** (Handy-style, Settings → Summarization): Qwen3 0.6B (built-in) · Llama 3.2 3B (2.0 GB) · Qwen3 4B Instruct (2.5 GB) · Qwen3 8B (5.0 GB) · GPT-OSS 20B (12.1 GB) — download/cancel/delete with progress, radio-select the active one. Qwen3 thinking disabled via `chat_template_kwargs`.

**M4 — day tracking**
- **Sampler:** frontmost app + focused-window title (Accessibility, degrades to app-name-only) every 5 s; idle-aware (3 min); blocks close on app/title change; min 5 s; pause/resume from menu bar. Stored in `activity_blocks` (same SQLite db).
- **Timeline screen:** per-day colored block bar with hover details, time-by-app totals with %, day navigation.
- **Day digest:** "Generate digest" runs the configured LLM over the day's blocks + meetings → `journal/YYYY-MM-DD.md` (## What I worked on / ## Meetings / ## Time allocation).

**M5 — screenshots, OCR, privacy**
- **Capture:** ScreenCaptureKit screenshot of the main display every N min (default 3, Settings slider), downscaled to ≤1500 px, HEIC. Skipped when idle (3 min), paused, locked, or when an excluded app is frontmost. Requires the Screen Recording permission (macOS prompts on first capture).
- **OCR:** Vision (`VNRecognizeTextRequest`, on-device) runs immediately; text goes into `ocr_fts` and is searchable under Search → Screen scope, and feeds day Q&A.
- **Encryption & retention:** each screenshot is AES-GCM encrypted with a per-install key in the macOS Keychain; pixels auto-delete after N days (default 14, Settings stepper) while OCR text is kept. Timeline shows a decrypted thumbnail filmstrip.
- **Exclusions:** comma-separated app list in Settings (preseeded with password managers); excluded time logs as "Private" with no titles and no screenshots.

**M6 — intelligence (partial)**
- **Ask your day:** free-form question box in Timeline — answers from the day's activity blocks + OCR'd screen text + meetings via the configured local LLM.
- **Semantic search:** transcript/summary chunks embedded with nomic-embed-text v1.5 (146 MB GGUF, auto-downloaded) on a second llama-server instance (port 17873, `--embeddings --pooling mean`). Vectors in SQLite, brute-force cosine (fast at personal scale, zero dependencies). Search → All shows a "Related (semantic)" section for meaning-matches that keywords missed; toggle in Settings → Search. Verified: "which storage technology did we pick" finds the SQLite discussion with 0 keyword overlap.
- **Detection upgrades:** mic-in-use is now event-driven (Core Audio property listeners on the default input device + device-change re-arm, plus NSWorkspace launch/quit notifications; 10 s safety poll remains for browser titles). **Browser meetings** (Google Meet, Jitsi, Whereby) detected via focused-window title when Accessibility is granted — the system-audio tap captures the browser's audio.
- Day digests (M4) + the model catalog (M3.5) complete the delivered M6 surface. **Not yet built:** VLM screenshot captions (needs a multimodal model + mmproj slot in LlamaServer).

## Known limitations / TODO

- Mic-in-use detection is a 3 s poll — replace with `AudioObjectAddPropertyListenerBlock` on the default input device (and re-arm on default-device change).
- Browser meetings (Google Meet) aren't detected yet — needs window-title check via Accessibility (M4 dependency).
- System track falls back gracefully if tap creation fails (mic-only recording + warning).
- `AVAudioFile` AAC encoding assumes Float32 tap/mic formats — verified on M-series; if `write(from:)` throws on exotic devices, fall back to `.caf` (PCM) and transcode post-meeting.
- Design doc says "MLX" for Parakeet; the shipped engine is FluidAudio's **CoreML** port (same model, mature Swift API, ANE-accelerated). MLX remains an option for M6 model-manager work.
- Summary prompt templates are hardcoded; user-editable template files land with M6.

## Layout

```
LokalBot/
├── project.yml                  # XcodeGen manifest
└── LokalBot/
    ├── LokalBotApp.swift        # @main, Window + MenuBarExtra + Settings scenes
    ├── Models/                  # Meeting, AppSettings
    ├── Services/
    │   ├── MeetingDetector.swift      # app + mic-in-use detection, debounce
    │   ├── MicRecorder.swift          # AVAudioEngine tap → mic.m4a
    │   ├── SystemAudioRecorder.swift  # Core Audio process tap → system.m4a
    │   └── StorageManager.swift       # folders, meta.json, library scan
    ├── Engines/TranscriptionEngine.swift  # M2 protocol + stub
    └── Views/                   # MenuBarView, MainWindowView, SettingsView
```

## Roadmap

M2 transcribe+summarize (MLX Parakeet, Ollama) → M3 search (FTS5) → M4 day tracking → M5 screenshots → M6 intelligence. See `lokalbot-design.md`.
