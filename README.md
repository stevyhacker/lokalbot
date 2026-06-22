# LokalBotV3 — M1 recorder · M2 transcribe & summarize · M3 search · M4 day tracking

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
- **Storage:** `~/Library/Application Support/com.dotenv.LokalBotV3/meetings/YYYY/MM/dd-slug/` with `meta.json` per meeting. (Bundle-id folder, not "LokalBotV3" — avoids colliding with any other app's `Application Support/LokalBotV3`.)
- **UI:** menu bar item (record state, start/stop, recent meetings) + main window (meeting list, Show in Finder, playback via QuickTime).

**M2 — transcription & summarization**
- **Transcription:** Parakeet TDT 0.6B via [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML, in-process, Neural Engine, ~190× realtime. v3 (25 languages, default) or v2 (English, higher recall). Model (~600 MB) auto-downloads from Hugging Face on first use.
- **Speaker attribution:** mic track = **Me**, system track = **Them**; merged by timestamp into `transcript.json` + `transcript.md`.
- **Summarization:** Ollama (`/api/chat`) or any OpenAI-compatible localhost server (LM Studio, vllm-mlx…). Map-reduce for long meetings. Output is `summary.md` with TL;DR / Key points / Decisions / Action items / Open questions. Strips `<think>` blocks from reasoning models.
- **Pipeline:** runs automatically when a recording stops (configurable); serial queue with per-meeting status in the UI; Process menu for manual / re-runs.
- **UI:** Summary + Transcript tabs in the meeting detail; Settings → Transcription/Summarization with Ollama auto-detection, model picker, and a "Test generation" button.
- **Headless mode:** `LokalBotV3 --process <meeting-folder> [--no-summary]` runs the pipeline without the UI (used for end-to-end testing).

**M3 — search & player**
- **Index:** SQLite + FTS5 (`lokalbotv3.sqlite` in the storage root, system SQLite — no dependency) over titles, transcript segments, and summaries. Segment-level rows carry their audio timestamp. Incremental re-index by file mtime, triggered on launch and after each pipeline run.
- **Search UI:** sidebar Meetings | Search; debounced search-as-you-type (last term prefix-matched), All/Transcripts/Summaries scope, «highlighted» snippets; clicking a transcript hit opens the meeting and plays from that timestamp.
- **Player:** mic + system tracks play in sync (shared device-time anchor); seek bar; click any transcript line to jump the audio there; the currently-playing segment is highlighted.
- **Headless:** `LokalBotV3 --search "<query>"` prints index hits (test hook).

**M3.5 — built-in LLM (no Ollama/LM Studio required)**
- `Scripts/fetch-llama.sh` (Xcode pre-build phase) vendors the pinned llama.cpp release (`b9587`, llama-server + dylibs, ~10 MB) and the default model (Qwen3 0.6B Q8_0, 0.64 GB) into `Vendor/`, which is copied into the app bundle. First build downloads once; afterwards cached.
- `LlamaServer` actor copies the server out of Resources into Application Support on first run, spawns it (`-ngl 99 --jinja`, port 17872), health-checks, restarts on model switch, terminates on app quit.
- **Model catalog** (Handy-style, Settings → Summarization): Qwen3 0.6B (built-in) · Llama 3.2 3B (2.0 GB) · Qwen3 4B Instruct (2.5 GB) · Qwen3 8B (5.0 GB) · GPT-OSS 20B (12.1 GB) — download/cancel/delete with progress, radio-select the active one. Qwen3 thinking disabled via `chat_template_kwargs`.

**M4 — day tracking**
- **Sampler:** frontmost app + focused-window title (Accessibility, degrades to app-name-only) every 5 s; idle-aware (3 min); blocks close on app/title change; min 5 s; pause/resume from menu bar. Stored in `activity_blocks` (same SQLite db).
- **Timeline screen:** per-day colored block bar with hover details, time-by-app totals with %, day navigation.
- **Day digest:** "Generate digest" runs the configured LLM over the day's blocks + meetings + OCR'd screen text → `journal/YYYY-MM-DD.md` (## What I worked on / ## Meetings / ## Time allocation).

**M5 — screenshots, OCR, privacy**
- **Capture:** ScreenCaptureKit screenshot of the main display every N min (default 3, Settings slider), downscaled to ≤1500 px, HEIC. Skipped when idle (3 min), paused, locked, or when an excluded app is frontmost. Requires the Screen Recording permission (macOS prompts on first capture).
- **OCR:** Vision (`VNRecognizeTextRequest`, on-device) runs immediately; text goes into `ocr_fts` and is searchable under Search → Screen scope, and feeds day Q&A and digests.
- **Encryption & retention:** each screenshot is AES-GCM encrypted with a per-install key in the macOS Keychain; pixels auto-delete after N days (default 14, Settings stepper) while OCR text is kept. Timeline shows a decrypted thumbnail filmstrip.
- **Exclusions:** comma-separated app list in Settings (preseeded with password managers); excluded time logs as "Private" with no titles and no screenshots.

**M6 — intelligence (partial)**
- **Ask your day:** free-form question box in Timeline — answers from the day's activity blocks + OCR'd screen text + meetings via the configured local LLM.
- **Semantic search:** transcript/summary chunks embedded with nomic-embed-text v1.5 (146 MB GGUF, auto-downloaded) on a second llama-server instance (port 17873, `--embeddings --pooling mean`). Vectors in SQLite, brute-force cosine (fast at personal scale, zero dependencies). Search → All shows a "Related (semantic)" section for meaning-matches that keywords missed; toggle in Settings → Search. Verified: "which storage technology did we pick" finds the SQLite discussion with 0 keyword overlap.
- **Detection upgrades:** mic-in-use is now event-driven (Core Audio property listeners on the default input device + device-change re-arm, plus NSWorkspace launch/quit notifications; 10 s safety poll remains for browser titles). **Browser meetings** (Google Meet, Jitsi, Whereby) detected via focused-window title when Accessibility is granted — the system-audio tap captures the browser's audio.
- Day digests (M4) + the model catalog (M3.5) complete the delivered M6 surface. **Not yet built:** VLM screenshot captions (needs a multimodal model + mmproj slot in LlamaServer).

**M7 — robustness, agent CLI, multi-speaker (this pass)**
- **Recording fixes:** the engine now reacts to `AVAudioEngineConfigurationChange` and re-installs the tap on the new device — switching to AirPods or unplugging a USB mic no longer truncates `mic.m4a`. The `MicRecorder` converter is drained on `stop()` so the trailing seconds of every recording are kept. `SystemAudioRecorder` watches the captured app's PID via `NSWorkspace.didTerminateApplicationNotification` and stops cleanly if the meeting app exits, instead of writing a silent half-track. AAC encoding moved off the Core Audio real-time IOProc thread onto a serial queue with copied buffers; the IOProcID is now destroyed on every error path (no more zombie taps the next launch). `MeetingDetector` removes its default-input-device listener on `stop()` (was leaked) and the new `AppSettings.stopDebounceSeconds` setting is finally wired through.
- **Audio source monitor:** a second detection signal (`AudioSourceMonitor`) polls Core Audio's process list and treats *silent → producing-output* transitions as meeting candidates. Catches the cases the mic-in-use signal missed (muted Zoom calls, meeting tabs opened before the mic). In automatic mode it auto-records recognised meeting bundles; otherwise a banner appears at the top of the main window.
- **Agent CLI:** new `lokalbot-cli` target (ArgumentParser) embedded in `Contents/Helpers/`, with subcommands `list / get / search / path`. Read-only access to the meeting library for coding agents (Claude Code, Codex CLI, Cursor, Gemini). Settings → Agent CLI symlinks the binary at `~/.local/bin/lokalbot-cli` and the bundled SKILL.md at `~/.agents/skills/lokalbot-cli/`. JSON by default, `--table` for humans. See `.agents/skills/lokalbot-cli/SKILL.md`.
- **Auto-update (Sparkle):** in-place signed updates via [Sparkle](https://github.com/sparkle-project/Sparkle) — a silent background check on launch plus a manual `Settings → Updates → Check for Updates…`, with the auto-check toggle bound to Sparkle's own preference. `AppUpdateManager` keeps the updater inert on dev builds (`LOKALBOTV3_DEV`) and until `SUFeedURL` + `SUPublicEDKey` are real (see `RELEASING.md`), so a fresh clone never self-updates. Replaces the old detection-only `UpdateChecker`.
- **Templated summaries:** Settings → Summarization now picks a notes template (Meeting / Lecture / Study guide / Podcast / Free-form) and a summary language (auto-detected from the transcript via `NLLanguageRecognizer`, with Simplified vs Traditional vs Cantonese script handling). Prompts come from `PromptTemplates`, the existing Markdown output format is unchanged.
- **Neural diarization (opt-in):** Settings → "Split Them by speaker" runs FluidAudio's offline pyannote-community-1 pipeline on `system.m4a` after transcription and relabels segments as "Them 1" / "Them 2" / …. Tuned for meetings (threshold 0.70, step ratio 0.15, min segment 0.3 s). Off by default — first run downloads ~100 MB of CoreML models from Hugging Face.

**M8 — distribution, updater & engine upgrades (this pass, ported/adapted from Cotabby)**
- **Dev/prod split:** `project.yml` builds `LokalBot` (prod, `com.dotenv.LokalBotV3`) and `LokalBot Dev` (`com.dotenv.LokalBotV3.dev`, `LOKALBOTV3_DEV`) from one target template, so running from Xcode holds its own Mic/Screen/Accessibility TCC grant and never disturbs the released app — and Sparkle is compiled out of dev.
- **Apple Intelligence backend:** Settings → Summarization adds an on-device Apple Intelligence engine (FoundationModels, macOS 26+) alongside Built-in/Ollama/OpenAI, gated so the app still builds and launches on 14.4. `ProcessingPipeline.makeTextEngine` routes to it.
- **Model manager:** in-app **Browse Hugging Face** (search GGUF repos, list `.gguf` files, download) plus resilient downloads (synchronous temp-file rescue, outcome classification, GGUF validation). `LocalLLM.swift` is split into `ModelCatalog` / `ModelDownloadManager` / `LlamaServer`.
- **Permissions:** the three TCC checks are centralized in `PermissionManager` (status cache, prompt, deep-link to the right System Settings pane, catch-up polling); `OnboardingView` is presentation-only over it.
- **Capability & power:** `DeviceInfo` / `HardwareCapabilityProbe` (`ModelFit` advisories per catalog row) / `PowerSourceMonitor` / `GenerationMetricsStore`, surfaced in Settings → System.
- **Logging:** `lokalbotv3Log` now routes through swift-log (`AppLog`) → stdout + a rotating `debug.log` (`FileLogHandler`).
- **Searchable settings + launch-at-login:** a search field filters Settings sections (`SettingsSearchRanker`); a `LaunchAtLogin` toggle under General.
- **Release & CI:** `Scripts/` gains DMG build (`build_release_dmg.py`), Sparkle appcast generation (`generate_appcast.py` + `appcast.template.xml`), test-DMG/clean helpers and `RELEASING.md`; `.github/workflows/` adds build/test/lint/xcodegen/release. Prompt helpers (`TokenCountEstimator`, `WordCountFormatter`, `PromptContextSanitizer`, `PromptSectionBudget`) keep summarization prompts within the model context.


## Testing

- **Unit tests** (`LokalBotTests`, in-process): `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test`. Pure-logic coverage of the prompt sanitizers, search ranker, model fit, transcript merging, settings codecs, etc.
- **UI tests** (`LokalBotUITests`, XCUITest): `Scripts/ui-tests.sh`. Drives the real `LokalBotV3.app` binary against a synthetic meetings library planted under a tmp `LOKALBOTV3_STORAGE_ROOT`. The app sees `LOKALBOTV3_UI_TEST=1` and skips every side-effectful subsystem (Core Audio polling, accessibility-trusted detector, Sparkle, screenshots), so no TCC permissions on the app are needed. Seven tests cover meeting-list grouping (+ Record button), sidebar navigation, detail tabs (Summary/Transcript), FTS5 search → deep-link, multi-select state, and both branches of the delete dialog (cancel keeps the files; confirm removes the rows **and** the on-disk folders). The first run needs the controlling terminal/IDE to hold **Automation → Xcode** and **Accessibility** TCC grants (granted once via System Settings); without them XCUITest fails with "Timed out while enabling automation mode."
- **End-to-end smoke** (`Scripts/e2e.sh`): exercises real audio, CoreML transcription, the bundled llama-server and SQLite via the headless flags. Skips flows that need ungranted TCC permissions; useful pre- and post-grant.

## Known limitations / TODO

- Sparkle ships with a placeholder `SUFeedURL` (`OWNER/REPO`) + `SUPublicEDKey` — generate a key and set the repo's appcast URL before the first release (see `RELEASING.md`); until then `AppUpdateManager` stays inert (no accidental self-update).
- System track falls back gracefully if tap creation fails (mic-only recording + warning).
- `AVAudioFile` AAC encoding assumes Float32 tap/mic formats — verified on M-series; if `write(from:)` throws on exotic devices, fall back to `.caf` (PCM) and transcode post-meeting.
- Design doc says "MLX" for Parakeet; the shipped engine is FluidAudio's **CoreML** port (same model, mature Swift API, ANE-accelerated). MLX remains an option for M6 model-manager work.

## Layout

```
LokalBot/
├── project.yml                          # XcodeGen manifest
├── CLI/                                 # `lokalbot-cli` ArgumentParser entry + commands
├── .agents/skills/lokalbot-cli/         # SKILL.md (embedded into Contents/Resources)
└── LokalBot/
    ├── LokalBotApp.swift                # @main, Window + MenuBarExtra + Settings scenes
    ├── CLISupport/                      # SessionLookup + SessionFormatter (shared with CLI)
    ├── Models/                          # Meeting, Transcript, AppSettings, NoteTemplate, SummaryLanguage
    ├── Services/
    │   ├── CoreAudioUtils.swift              # process taps, default-device helpers
    │   ├── MeetingDetector.swift             # mic-in-use + meeting-app detection
    │   ├── AudioSourceMonitor.swift          # "app just started producing output" signal
    │   ├── MicRecorder.swift                 # AVAudioEngine tap → mic.m4a
    │   ├── SystemAudioRecorder.swift         # Core Audio process tap → system.m4a
    │   ├── NeuralDiarizationEngine.swift     # FluidAudio offline diarizer wrapper
    │   ├── PromptTemplates.swift             # template + language prompt synthesis
    │   ├── AppUpdateManager.swift            # Sparkle updater lifecycle
    │   ├── PermissionManager.swift           # centralized Mic/Screen/Accessibility TCC
    │   ├── LokalBotCLIInstaller.swift        # symlink installer for the CLI
    │   └── StorageManager.swift              # folders, meta.json, library scan
    ├── Engines/                              # TranscriptionEngine, TextEngine, AppleIntelligenceEngine; ModelCatalog/ModelDownloadManager/LlamaServer
    └── Views/                                # MenuBarView, MainWindowView, SettingsView, banners
```

## Roadmap

M2 transcribe+summarize (MLX Parakeet, Ollama) → M3 search (FTS5) → M4 day tracking → M5 screenshots → M6 intelligence. See `lokalbot-design.md`.
