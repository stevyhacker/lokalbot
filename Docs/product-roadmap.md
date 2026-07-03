# LokalBot — Product Roadmap (code-grounded)

_Date: 2026-07-03. Provenance: derived from a code audit of the tree as of `91f9a90`, deliberately ignoring existing marketing/redesign docs. Every claim below is anchored to a file in the repo. Ranked by importance to users._

## Thesis

The engineering is unusually disciplined (zero TODO/FIXME in app code, accessibility IDs everywhere, crash-recovering pipeline jobs, hermetic e2e harness). The product, however, is entirely **post-hoc**: everything valuable happens after the moment — recording ends → `ProcessingPipeline` runs → summary appears. And the configuration surface is a power-user cockpit (~72 persisted settings in `AppSettings.swift`, 9 ASR engines, 4 LLM backends, an HF GGUF browser).

The two biggest veins of untapped potential:

1. **The moments the code currently skips** — during the meeting, and at the moment of consent.
2. **Joins between systems that already exist** — calendar attendees × diarization, dictation's streaming ASR × meeting audio, the CLI's read-only store × the agent ecosystem.

---

## Ranked items

### 1. Live, during-meeting surface — **Add**

**User impact: every user, every meeting, at the moment of use. Effort: L.**

**Grounding.** `Services/ProcessingPipeline.swift` only runs after recording stops; during a call the app shows a timer. But streaming ASR with committed/tentative two-tone text already exists in `LokalBot/Dictation/` — the capability is in the tree, just pointed at the wrong audio source.

**Path forward:**
1. Extract the streaming recognizer out of `Dictation/` into a shared component (keep Dictation as its first consumer; no behavior change there).
2. Tee the mic audio: `Services/MicRecorder.swift` already owns an `AVAudioEngine` tap — feed a second consumer (the streaming recognizer) while recording. Start with the "Me" side only; add the system-tap side (`SystemAudioRecorder`) once perf is proven, or stream the mixed signal.
3. UI: a live-transcript panel on the recording surface (recording row / detail view), reusing the committed/tentative rendering from Dictation. Menu-bar "catch me up" (summarize the live transcript so far via `TextEngine`) as a fast follow.
4. Quick-notes pad during recording: write `notes.md` into the meeting folder (`meetings/YYYY/MM/dd-slug/`), and merge it into the summary prompt in `ProcessingPipeline` / `PromptTemplates.swift`.
5. Perf guardrails: pause Cotyping generation while a meeting records (precedent: commit `91f9a90` already pauses auto-screenshots during recording).

**Done when:** a recording in progress shows live text within ~2 s of speech; notes typed during the call appear in the recap; CPU/RAM stays acceptable on a 16 GB machine (see item 8).

**Risks:** streaming + recording + diarization simultaneously is the heaviest workload the app will ever run — land item 8 (memory governor) in the same wave or immediately after.

---

### 2. Real consent flow for auto-record — **Fix**

**User impact: trust + legal exposure; brand-critical. Effort: S.**

**Grounding.** Default mode is `.automatic` (`Models/AppSettings.swift:25`). The middle option — "ask before recording" — is a stub: `notifyMeetingDetected` calls `NSSound.beep()` (`LokalBotApp.swift:560-565`). A privacy-first product silently auto-records calls (two-party-consent implications) with a beep as its consent UI.

**Path forward:**
1. Implement the `UNUserNotification` with **Record** / **Ignore** action buttons in `notifyMeetingDetected`. `Services/RecordingNotifier.swift` already handles notification authorization — reuse it.
2. Auto-dismiss after the meeting-detection window closes; tapping Record starts recording via the existing `RecordingController` entry point.
3. Stretch: a short rolling pre-record ring buffer in `MicRecorder` while in `.ask` mode, so accepting the prompt doesn't lose the first minute. Flag as its own PR; it touches the recorder.
4. Flip the **default for new installs** to `.ask`. Keep existing users on their current choice (the `AppSettings` decode fallback already preserves persisted values — just change the default in `defaults`).
5. Tests: unit-test the detection→notification policy as a pure type (follow the Cotyping policy-type pattern); UI-test the Settings picker (`SettingsView.swift:186`).

**Done when:** `.ask` shows an actionable notification, Record starts a capture, and new installs default to `.ask`.

---

### 3. Signed distribution + working updates — **Fix (ops, not code)**

**User impact: gates literally everything else. Effort: S–M, mostly process.**

**Grounding.** `Services/AppUpdateManager.swift:97-106` refuses to start Sparkle on placeholder feed/key values — correct behavior, but it means shipped builds have **no update channel**. The DMG is currently unsigned, so new users fight Gatekeeper.

**Path forward:**
1. Apple Developer account → Developer ID Application cert.
2. Wire notarization + stapling into `Scripts/build_release_dmg.py` (`notarytool submit --wait`, `stapler staple`).
3. Generate the Sparkle ed25519 keypair; commit only `SUPublicEDKey` in `project.yml` (the private key never enters the repo — `RELEASING.md` already states this).
4. Host `appcast.xml` on the website (`web/` deploys to Vercel; DMGs can stay on GitHub Releases) and set `SUFeedURL`.
5. Verify `AppUpdateManager` activates on a real build and an old build updates to a new one.

**Done when:** a fresh Mac double-clicks the DMG with no Gatekeeper ceremony, and an installed 0.1.x self-updates.

---

### 4. Structured outcomes, not a summary blob — **Change**

**User impact: the value of every recap. Effort: M.**

**Grounding.** The pipeline ends at `summary.md`. `Models/NoteTemplate.swift` has five templates but output is prose. Nothing extracts action items / decisions / open questions as *data*, even though `SQLiteDatabase` already has FTS tables and the chat agent has five read-only tools (`Services/Chat/MeetingChatTools.swift:203-237`).

**Path forward:**
1. Add an extraction step to `ProcessingPipeline` after summarization: a second, **grammar-constrained** generation pass (see item 7's infrastructure) producing JSON — `{action_items: [{text, owner?, due?}], decisions: [], questions: []}`.
2. Storage: files remain source of truth — write `outcomes.json` into the meeting folder; mirror into new SQLite tables for cross-meeting queries.
3. UI: outcome chips on the recap; an "Open action items" rollup in the day overview; outstanding items feed the day digest (`journal/`).
4. New chat tool `get_action_items(day|range)` alongside the existing five in `MeetingChatTools`.
5. Tests: unit-test JSON parse/migration with malformed-output fixtures; extend `Scripts/e2e.sh`'s `--process` flow to assert `outcomes.json` exists.

**Done when:** "what did I commit to this week?" is answerable in Ask, from data rather than model recall.

**Risks:** small local models produce garbage extractions — grammar-constrained decoding (item 7) is the mitigation, which is why item 7's infra should land first or together.

---

### 5. "Auto" model pilot + demote the cockpit — **Change / Remove**

**User impact: every new user's first hour; ongoing choice paralysis. Effort: M.**

**Grounding.** Nine transcription engines (`Engines/TranscriptionEngine.swift:42-51`: Parakeet v3/v2, Qwen3-ASR ×2, Granite, Whisper, SenseVoice, GigaAM, Cohere-legacy), four summarizer backends (`AppSettings.swift:11-15`), an HF GGUF browser (`ModelsView.swift:231-317`), separate Cotyping + embedding pickers. ~72 persisted settings. First recap can stall on a lazy ~600 MB Parakeet download (`MainWindowView.swift:420`).

**Path forward:**
1. Add an **Auto** engine option: a pure policy type mapping (language, duration, power source via `PowerSourceMonitor`) → engine choice among installed models. Default: Parakeet v3 for speed; escalate to Whisper for languages Parakeet doesn't cover. Unit-test the policy exhaustively — it's pure.
2. Move the raw engine list, HF browser, and Ollama/OpenAI-compatible backend config behind **Settings → Advanced**. Keep them — they serve the local-LLM enthusiast segment — but stop presenting them to everyone.
3. **Delete** the Cohere-legacy engine (already hidden from new installs — finish the job). Demote or remove SenseVoice and GigaAM unless there's evidence of use. Target: 9 engines → ~4 visible (Auto, Parakeet, Whisper, Qwen).
4. Onboarding prefetch: move the default-model download into the onboarding flow with visible progress (`GettingStartedCard` in `MainWindowView.swift:692-822` already tracks it; `ModelDownloadManager` does the work) so the first recap is never the first wait.
5. Settings audit: group the 72 `AppSettings` vars, prune duplicates; keep decode fallbacks so removed keys don't break existing installs.

**Done when:** a new user never chooses a model to get a good first recap, and the default Settings surface fits on two screens.

---

### 6. Named speakers — **Add**

**User impact: every transcript and summary reads better. Effort: M.**

**Grounding.** Diarization (`Services/NeuralDiarizationEngine.swift`, FluidAudio) yields Me/Them/Speaker N. The read-only calendar integration (`Services/Calendar/MeetingMatcher.swift`, `EventKitCalendarEventProvider.swift`) already matches meetings to events — **attendee names are sitting right there, unjoined**.

**Path forward:**
1. When `MeetingMatcher` confirms an event, write attendee display names into the meeting's `meta.json` (names only, local).
2. Mapping heuristics: "Me" = mic channel (already true); for a 1-on-1, the single remote speaker gets the single remote attendee's name; for N-way calls, offer name assignment in the meeting detail view (tap a speaker label → pick from attendees). Persist the mapping in `transcript.json`.
3. Feed names into `PromptTemplates` so summaries say "Sarah agreed to ship Friday" instead of "Speaker 2".
4. Later (separate effort): cross-meeting voice memory via FluidAudio speaker embeddings — a local voiceprint store, behind a Privacy-pane setting, on-device only.

**Done when:** a 1-on-1 recorded off a calendar event produces a transcript with both participants named, zero manual steps.

---

### 7. Chat receipts + grammar-enforced tool calls — **Change**

**User impact: trust in every answer Ask gives. Effort: M.**

**Grounding.** `Services/Chat/ChatAgent.swift` extracts tool calls by regex and maintains a strip-list of ~a dozen vendor token formats (`ChatAgent.swift:272-287`) — a tax paid because small local models emit sloppy JSON. The bundled llama.cpp server (`Engines/LlamaServer.swift`, pinned `b9844`) supports GBNF grammars / `json_schema` on its completion endpoints. Tools already return meeting ids + timestamps, and search hits already deep-link (`app.openSearchHit`), but chat answers are plain text with no receipts.

**Path forward:**
1. When the agent loop expects a tool step, send a grammar/`json_schema` constraint so the tool-call JSON is enforced **at decode time**. Leave the final-answer turn unconstrained (grammar-forcing prose degrades it). This deletes most of the strip-list and the "pythonic call" fallback parsing.
2. Require citation markers in final answers (e.g. `[meeting:<id>@<ts>]`), populated from tool results; render them in `ChatView` as tappable links using the existing search-hit deep-link path (seek-to-timestamp).
3. Reuse the same grammar infrastructure for item 4's outcomes extraction.
4. Tests: the existing `ChatAgent` parse tests shrink; add routing tests for tool-step vs. answer-step constraint selection.

**Done when:** a chat answer about a meeting carries clickable timestamps that jump to the audio, and tool-call parse failures effectively disappear from logs.

---

### 8. One memory governor across the runtimes — **Add**

**User impact: whether the app feels magic or makes the Mac swap. Effort: M.**

**Grounding.** Three model runtimes can be co-resident: Cotyping's in-process llama (`Cotyping/Llama/`), the llama-server process (`Engines/LlamaServer.swift`), and ASR/embedding models. The code already fights this locally — "would leave TWO ~6.66 GB copies of the weights resident" (`Cotyping/Llama/CotypingEngineSelector.swift:158`) — but there is no global budget.

**Path forward:**
1. A `ModelResidency` actor: every runtime registers load/unload; the governor enforces a budget (a fraction of physical RAM) with LRU eviction. Cotyping already has awaited unload paths (`CotypingEngineSelector.unload`) and `LlamaServer` manages its own process lifecycle — wire both in.
2. Shared-model fast path: when the Cotyping model and summary model are the same GGUF, don't hold two copies — route one consumer through the other's runtime.
3. Surface it: a "Models in memory: X GB" line in Settings → System (hardware metrics already live there), and a menu-bar warning state under pressure.
4. Policy is a pure type — unit-test the eviction/budget logic without loading any model.

**Done when:** worst case (recording + live transcript + Cotyping enabled) stays within budget on a 16 GB machine, with visible accounting.

---

### 9. Event-driven screen capture + capture health — **Change**

**User impact: better day-recall with less disk/CPU; trust that capture is actually working. Effort: M–L.**

**Grounding.** `Services/ScreenshotService.swift` shoots on a timer, OCRs separately from the 5-second `ActivityTracker` sampler — redundant frames, missed moments, OCR CPU burn. Background capture can fail silently.

**Path forward:**
1. Trigger captures on events instead of the timer: app activation (NSWorkspace, already observed for meeting detection), window-title change (the browser-title poll / AX observers exist), typing pause, clipboard copy, with a slow idle fallback. Record the trigger + source in each row.
2. Prefer the focused window's **accessibility text** over OCR; fall back to Vision OCR only when AX yields little (canvas apps, PDFs, Figma). Tag rows `accessibility` / `ocr`.
3. Keep the AES-GCM sealing, per-install Keychain key, and retention pruning exactly as they are.
4. Health surface in Settings → Day tracking: last capture time, pending OCR jobs, disk usage (`StorageManager`), permission state.
5. Migration: old timer-based rows stay valid; the index schema gains columns, doesn't break.

**Done when:** disk growth per day drops while `search_screen` hit quality improves, and a user can see at a glance that capture is alive.

---

### 10. Decide Cotyping's place; harvest its machinery — **Change**

**User impact: the differentiator, made legible. Effort: M for transform-selection; discipline for the freeze.**

**Grounding.** Cotyping is the largest subsystem (~9.7k lines, 51 files — a second product), off by default, with a deep advanced-options tree (generation, rendering, accept/insert, learning). Its infrastructure — AX focus tracker, insertion strategies, in-process llama runtime — is general-purpose.

**Path forward:**
1. **Freeze the knob tree.** Use `GenerationMetricsStore` data to find dead options and remove them. New Cotyping options require removing an old one.
2. Build **transform-selection** on the same machinery: a hotkey/menu command reads the selected text via AX, applies an instruction (rewrite / fix grammar / translate / summarize), and inserts via the existing insertion strategies with undo. Same runtime, same exclusion model (password fields, excluded apps/domains) — and far easier to explain than ghost-text autocomplete.
3. Ship transform-selection as the headline "Type" feature; Cotyping remains the power feature underneath.

**Done when:** a user who never enables autocomplete still gets daily value from the Type pillar.

---

### 11. Read-only MCP server — **Add**

**User impact: every Claude/Cursor user's agent can use their meeting library. Effort: S.**

**Grounding.** `lokalbot-cli` (`LokalBot/CLISupport/`, ~273 lines, shared by direct source inclusion per `project.yml`) already exposes `list/get/search/path` read-only. `MeetingChatTools` defines the same five queries with descriptions. The cheapest large-audience feature in the repo.

**Path forward:**
1. New `lokalbot-mcp` tool target in `project.yml`, mirroring the CLI's source-inclusion pattern; embed in `Contents/Helpers/` the same way. Run `xcodegen generate` after.
2. stdio JSON-RPC MCP server exposing `search_meetings`, `list_meetings`, `get_meeting`, `activity_summary`, `search_screen` — same backing queries as `CLISupport` + `MeetingChatTools`. **Read-only, no destructive tools.**
3. Install/uninstall via the existing `LokalBotCLIInstaller` flow; one-paragraph setup snippets for Claude Code and Cursor in the README.

**Done when:** `claude mcp add lokalbot ...` lets an agent answer "what did I discuss with X last week?" from the local library.

---

## Removals (explicit)

| What | Where | Why |
|---|---|---|
| Cohere-legacy ASR engine | `Engines/TranscriptionEngine.swift` + catalog | Already hidden from new installs; delete the code path. |
| SenseVoice, GigaAM engines (demote or delete) | same | Each is a download path, failure mode, and QA cell; keep only if usage justifies. |
| The `NSSound.beep()` `.ask` stub | `LokalBotApp.swift:560-565` | Replaced by item 2 — do not keep alongside. |
| Dead Cotyping advanced options | `Views/CotypingView.swift` + `AppSettings` | Metrics-driven prune (item 10.1); keep decode fallbacks. |

## Do not touch

- **The on-device invariant.** No telemetry, no cloud calls, localhost only. Every item above is implementable without a new network surface.
- **File-based markdown storage** (`meetings/`, `journal/`). It *is* the portability/export story; new data (outcomes, attendees) goes into the meeting folder first, SQLite second.
- **The headless/e2e harness** (`HeadlessCommands.swift`, `Scripts/e2e.sh`) — extend it for every pipeline change; it's why the pipeline is trustworthy.
- **Pinned dependencies** (FluidAudio exact, Sparkle exact, llama.cpp `b9844`) — bump only deliberately, per `CLAUDE.md`.

## Sequencing

**Wave 0 — this week (small, unblocking):**
- Item 3 (signing + appcast) — gates everything.
- Item 2 (consent notification + default flip).
- Delete Cohere-legacy.

**Wave 1 — foundation (infra that later items reuse):**
- Item 7 step 1 (grammar-constrained decoding infra).
- Item 5 (Auto engine, onboarding prefetch, cockpit demotion).
- Item 4 (structured outcomes — uses the grammar infra).

**Wave 2 — the product leap:**
- Item 1 (live meeting surface).
- Item 8 (memory governor — same wave, the live surface needs it).
- Item 6 (named speakers).

**Wave 3 — breadth:**
- Item 7 steps 2–3 (citations UI).
- Item 9 (event-driven capture + health).
- Item 10 (transform-selection).
- Item 11 (MCP server).

## Working conventions (apply to every item)

- After adding/removing source files or targets: `xcodegen generate` (never edit the `.xcodeproj`).
- Unit tests: scheme **LokalBot** (not "LokalBot Dev"); UI tests via `Scripts/ui-tests.sh`; pipeline changes also run `Scripts/install-app.sh && Scripts/e2e.sh`.
- New policy/decision logic goes in small pure types with unit tests (the Cotyping pattern) — no AX, no audio, no model needed to test them.
- `default.profraw` is regenerated by test runs and gitignored — never commit it.
- Keep `swiftlint --strict` clean (see commit `8e15b14`).
