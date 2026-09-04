<div align="center">

<img src="web/assets/lokalbot-icon.svg" width="110" alt="LokalBot icon" />

# LokalBot

**A local LLM workhorse that keeps a private memory of your workday. Open source, on-device by default.**

Records both sides of meetings without a bot, turns conversations and the workday context you choose into searchable memory, and helps you recall decisions, draft follow-ups, dictate, and autocomplete in any app.

No account. No telemetry. No LokalBot cloud. [Verify the local path yourself](#privacy--verify-it).

[![Download LokalBot for macOS](https://img.shields.io/badge/%E2%80%82Download%20for%20macOS%E2%80%82-LokalBot.dmg-0969da?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg)

<sub>Free · Developer ID signed, notarized &amp; stapled · Apple Silicon, macOS 15+ · [all releases](https://github.com/stevyhacker/lokalbot/releases)</sub>

[![Latest release](https://img.shields.io/github/v/release/stevyhacker/lokalbot?color=1f6feb&label=release)](https://github.com/stevyhacker/lokalbot/releases/latest)
![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-000000?logo=apple&logoColor=white)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-2ea043)](LICENSE)

<video src="https://github.com/user-attachments/assets/6764ed3b-df44-45fd-8569-13c440091aec" controls title="LokalBot 30-second feature demo: cited recall, bot-free meeting capture, local Dictation and Autocomplete, and verifiable local processing"></video>

<sub><strong>30-second feature demo with voiceover</strong> · Cited recall, bot-free meeting capture, Dictation, Autocomplete, and verifiable local processing · <a href="web/assets/hero-demo.mp4">open the MP4 directly</a></sub>

[Features](#features) · [How it works](#how-it-works) · [Privacy — verify it](#privacy--verify-it) · [Download](#download) · [FAQ](#faq) · [Build from source](#build-from-source)

</div>

---

The memory starts with meetings. Your mic is captured as **Me** and a Core Audio tap on the meeting app as **Them**, so speaker labels come free and no bot joins the call. LokalBot then produces a recap, separates decisions from action items, and links outcomes back to the audio that supports them.

The same private library connects four moves: **Remember** meetings and optional day context. **Recall** decisions with evidence. **Write** with Dictation and Autocomplete. **Act** through reviewable actions, fixed-scope local routines, exports, and approved Agent Mode sessions.

**Network access is limited to model/runtime downloads, optional update checks, remote inference origins you explicitly approve, and network-capable Agent Mode commands you explicitly approve.** Details in [Privacy](#privacy--verify-it).

## Why LokalBot

| | |
| --- | --- |
| **Bot-free capture** | Two synchronized audio tracks record you and the meeting app without adding a participant to the call. |
| **Outcomes, not transcript piles** | Review decisions, action items, open questions, and the day-level tasks that still need attention. |
| **Evidence attached** | Search by words or meaning, open the exact meeting or retained moment, and jump to the supporting audio. |
| **Local by default** | Built-in transcription, summaries, search, and writing run on your Mac; remote inference is explicit and per-origin approved. |
| **Free and auditable** | No account or API key is required. The GPLv3 source and network traffic are both yours to inspect. |

<div align="center">

<img src="Assets/superapp-hero.svg" alt="LokalBot super-app map: one on-device language model at the center, connected to meetings, cotyping autocomplete, chat, search, the day timeline, the agent CLI, and bring-your-own models" width="680">

</div>

## See it in action

**Start with what needs attention.** Today combines the day digest with reviewable meeting actions and one-click access to Ask, the Timeline, and Agent Mode.

<div align="center"><a href="Assets/screenshots/today.png"><img src="Assets/screenshots/today.png" alt="LokalBot Today showing the day summary, digest tasks, and meeting actions that need attention" width="920"></a></div>

**Turn a call into outcomes you can act on.** Check off or reassign action items, review decisions, and jump from an outcome to its cited audio or transcript evidence.

<div align="center"><a href="Assets/screenshots/meetings-summary.png"><img src="Assets/screenshots/meetings-summary.png" alt="LokalBot Meetings showing an audio player, reviewable action items, cited decisions, and a structured summary" width="920"></a></div>

**Recall without leaving the app you are in.** Quick Recall searches saved moments, captured text, and meeting transcripts from one shortcut.

<div align="center"><a href="Assets/screenshots/quick-recall.png"><img src="Assets/screenshots/quick-recall.png" alt="LokalBot Quick Recall searching Redis across a saved Slack moment, captured screen text, and meeting transcripts" width="660"></a></div>

**Understand the day as work, not raw telemetry.** Timeline groups activity into work sessions and meetings; the raw capture remains available when you need exact evidence or cleanup.

<div align="center"><a href="Assets/screenshots/timeline.png"><img src="Assets/screenshots/timeline.png" alt="LokalBot Timeline showing a day digest, grouped work sessions, meetings, and access to the underlying capture evidence" width="920"></a></div>

| | |
| :--: | :--: |
| <a href="Assets/screenshots/cotyping.png"><img src="Assets/screenshots/cotyping.png" alt="LokalBot Type showing the Autocomplete readiness check, in-app suggestion preview, and two-step rehearsal" width="440"></a><br>**Autocomplete** — rehearse locally, then enable Cotyping in almost any app | <a href="Assets/screenshots/models.png"><img src="Assets/screenshots/models.png" alt="LokalBot model settings showing the Transcribe, Think, and Autocomplete roles, recommended presets, and model storage" width="440"></a><br>**Model stack** — see readiness and change each local role in one place |

<sub>Captured at Retina resolution from the real macOS UI with a synthetic demo library. Click any image for the full-resolution frame; no personal meeting or screen data is shown.</sub>

## Features

### Remember

- **Records both sides of the call.** Auto-detects Zoom, Teams, Meet, Slack, Webex, and FaceTime, then captures *you* and *them* on two synced tracks — no bot in the participant list.
- **Follows the call live.** A live meeting view while you talk: quick notes that land in the finished meeting, plus an opt-in rolling transcript.
- **Transcribes locally.** IBM Granite Speech 4.1 by default; Parakeet for speed (up to ~190× realtime in local benchmarks), Whisper for 99 languages, Qwen3-ASR for harder recordings.
- **Turns talk into outcomes.** After processing, you get a TL;DR, decisions, action items, and open questions. Mark work done, reassign it, open it in Agent Mode, or jump to the supporting evidence.
- **Explains the day.** Today surfaces the digest and open actions; Timeline groups activity into work sessions and meetings while preserving access to the raw evidence.

### Recall

- **Search every word you've heard.** Full-text *and* meaning-based search — jump straight to the audio behind any hit.
- **Chat with your meetings.** "What did we decide?" answered from your library, with citations. Kokoro TTS can read answers aloud on-device.
- **Recall with evidence.** Choose activity only, accessible text, or accessible text plus encrypted visuals. Search captured text by meaning, app, or date; open the exact retained moment behind an answer; save important moments; or inspect a work session down to its raw capture.

### Write

- **Dictation — voice typing anywhere.** Hold **⌥ Space**, talk, release: transcribed on-device and pasted at the cursor. Pauses your music first; deletes the audio after. Opt-in.
- **Autocomplete (Cotyping).** Ghost text appears as you type in almost any app; **Tab** accepts. The Type screen lets you test and rehearse the real local pipeline before enabling it system-wide. Opt-in; never reads password fields.

### Act

- **Move reviewed work forward.** Send a meeting action or today's open list into Agent Mode with its source context attached; file and shell access still follow the configured approval policy.
- **Automate drafts safely.** Opt-in routines create local post-meeting follow-ups, stand-ups, weekly work logs, action rollups, and journal notes. They use fixed local scopes, write only to your chosen folder, and cannot run scripts, send messages, or contact services.
- **Private by construction.** Accessible text is preferred and local OCR fills gaps. Private windows, excluded apps/domains, secure fields, and detected credentials fail closed; credentials force text-only retention. Optional pixels are AES-GCM encrypted and auto-delete after 14 days unless you explicitly save a moment. External screen-memory tools have an independent, time-scoped permission.

Power users: bring your own model (any GGUF, Ollama, an OpenAI-compatible server, or Apple Intelligence), run the embedded coding agent, or give your coding agents read-only library access — see [For developers & agents](#for-developers--agents). Full technical detail: [DEVELOPMENT.md](DEVELOPMENT.md).

## How it works

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/architecture-diagram.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/architecture-diagram-light.svg">
  <img alt="LokalBot's local-first pipeline: capture (mic as Me via AVAudioEngine, system audio as Them via a Core Audio process tap) → transcribe on-device → summarize with the built-in local model or an explicitly approved server → index locally in SQLite. Model and update downloads use the network." src="Assets/architecture-diagram-light.svg" width="880">
</picture>

</div>

1. **It notices the meeting.** LokalBot automatically starts when it detects a call by default (configurable: auto / ask / manual), or you start it from the menu bar.
2. **It creates outcomes with evidence.** The selected engines turn audio into a labeled transcript, structured recap, decisions, and action items. The built-in defaults run on-device; first use may include model downloads.
3. **It builds a local working memory.** Meetings, outcomes, activity, and optional screen context land in local files and SQLite you can search, replay, review, or hand to trusted tools.

### Example model stack and performance

This measured higher-capacity example occupies about **12.4 GB** after every model below has been downloaded. It was tested on a **48 GB M4 Max MacBook Pro** using LokalBot's bundled llama.cpp runtime with full Metal offload. It is not the default preset: the current Recommended stack uses the smaller LFM2.5 1.2B model for Autocomplete.

| Role | Model | Quantization / format | Model files | Measured generation |
| --- | --- | --- | ---: | ---: |
| Transcription | IBM Granite Speech 4.1 2B | `Q4_K_M` + F16 projector | 2.30 GB | ASR; use realtime factor |
| Summaries and chat | Qwen3.5 4B | `Q4_K_M` | 2.74 GB | ~100 tokens/s |
| Autocomplete | Gemma 4 E4B | `UD-Q5_K_XL` | 6.66 GB | ~78 tokens/s |
| Semantic search | Qwen3-Embedding 0.6B | `Q8_0` | 0.64 GB | Embeddings; not generative |
| Speaker diarization | pyannote-community-1 via FluidAudio | Core ML | ~0.10 GB | Diarization; not generative |

Explore the [interactive benchmark summary](https://huggingface.co/spaces/stevyhacker/lokalbot-benchmarks) and the [recommended local model stack](https://huggingface.co/collections/stevyhacker/lokalbot-recommended-local-stack).

Generation speed varies with context length, thermals, and other workloads. Model files download on first use, so features you do not enable do not incur their full model footprint.

Embeddings live in SQLite with brute-force cosine similarity, because at personal scale brute force is instant.

## Privacy — verify it

Privacy is the architecture. Audio, transcripts, summaries, embeddings, screenshots, and activity live in local files and SQLite under your account. There is no account or telemetry, and audio is never sent to a LokalBot service.

Depending on the features and backends you enable, LokalBot may make these outbound connections:

1. **One-time model downloads** the first time you use a local engine — weights from Hugging Face, sherpa-onnx archives from GitHub. Once cached, those local engines no longer need network access.
2. **A backend you explicitly configure** — point summaries, chat, or Agent Mode at Ollama or any OpenAI-compatible server and traffic goes only where you send it, after a per-origin approval. The built-in llama.cpp runtime is localhost-only.
3. **Agent Mode setup, if you enable it** — a one-time, checksum-verified download of the Bun runtime and the lockfile-pinned pi package. The pi runtime disables its own telemetry and version checks; LLM requests stay local when you select the built-in backend.
4. **App updates** via Sparkle — automatic checks are on by default for new installs and can be disabled in Settings; update downloads come from GitHub Releases.
5. **Agent Mode commands you approve** — approved shell commands run with your macOS user permissions and can access any network destination available to your account. Their destinations and data handling are outside LokalBot's control.

To verify the built-in path, download the required models first, select the built-in backend, turn off automatic update checks, then run Little Snitch (or `lsof -i -nP | grep LokalBot`) while it records, transcribes, and summarizes a meeting. LokalBot should make no outbound connection during that processing cycle; approved shell tools are separate processes and may connect when you permit them.

App Sandbox is intentionally off — Core Audio process taps don't work sandboxed. That's why LokalBot ships as a notarized Developer ID app rather than through the App Store.

Full policy: [PRIVACY.md](PRIVACY.md) · report a vulnerability privately: [SECURITY.md](SECURITY.md)

## Download

**[Download LokalBot.dmg](https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg)** — free · [all releases and notes](https://github.com/stevyhacker/lokalbot/releases)

Developer ID signed, notarized, stapled, and verified by Gatekeeper. Release tooling automates the same sign → notarize → staple checks for future releases.

- Apple Silicon Mac (M1 or later)
- macOS 15.0 or later
- Disk for the models you pick (~0.5–18 GB)

Drag to Applications and open. Expect Microphone and System Audio prompts on your first recording; the models you select download on first use, and built-in inference can then run offline.

## Switching from a cloud notetaker?

The useful comparison is where capture, transcription, summaries, and stored data live, plus whether the source is auditable. Products and prices change quickly, so the dated, sourced comparisons are maintained separately: [vs Granola](https://www.lokalbot.com/lokalbot-vs-granola) · [vs Rewind](https://www.lokalbot.com/lokalbot-vs-rewind) · [vs Superwhisper](https://www.lokalbot.com/lokalbot-vs-superwhisper) · [vs Hyprnote](https://www.lokalbot.com/lokalbot-vs-hyprnote)

## FAQ

<details>
<summary>Does anything leave my Mac?</summary>

Audio stays on your Mac. Transcripts, summaries, screenshots, and workday context stay local with the built-in backend; if you approve a non-loopback Ollama or OpenAI-compatible origin, LokalBot sends that server the context required for requests. The app also connects for model/runtime downloads, optional update checks, and network access by Agent Mode commands you explicitly approve. See [PRIVACY.md](PRIVACY.md).
</details>

<details>
<summary>Is it really free — and will it stay free?</summary>

Free and open source under GPLv3 today, with no account, subscription, or telemetry. Copyleft means a future rug-pull would be hard by construction: any distributed fork must ship its source under the GPL too.
</details>

<details>
<summary>Which Macs — and why Apple Silicon only?</summary>

Apple Silicon (M1 and later) on macOS 15.0+, by design: LokalBot is built around the Neural Engine, MLX, and Core Audio process taps. There is no Intel, Windows, or Linux build planned.
</details>

<details>
<summary>How does it record both sides?</summary>

Your microphone is one track, labeled **Me**. A Core Audio process tap on the meeting app is the other, labeled **Them**. That split gives you speaker labels for free — no bot joins the call.
</details>

<details>
<summary>How is this different from Rewind or screenpipe?</summary>

They proved people want a computer that remembers. Rewind became Limitless and moved cloud-first; screenpipe is a developer library you build on. LokalBot is a finished GPLv3 app: install it, and capture, transcription, summaries, and memory run on-device by default, with source you can audit. Dated comparisons: [vs Rewind](https://www.lokalbot.com/lokalbot-vs-rewind) · [vs Granola](https://www.lokalbot.com/lokalbot-vs-granola).
</details>

<details>
<summary>Can I use my own model?</summary>

Yes. Use the built-in llama.cpp runtime with any GGUF you download (there's a Hugging Face browser in Settings), or point LokalBot at Ollama, any OpenAI-compatible server, or Apple Intelligence.
</details>

<details>
<summary>Is my screen being watched?</summary>

Fresh installs select day tracking with text and encrypted visual context by default. Collection starts only after you grant macOS Accessibility and Screen Recording permissions, and you can turn off tracking or choose a less detailed mode at any time. Visuals are deleted after 14 days by default; a moment you explicitly save is retained until you unsave or delete it. Private/incognito windows, excluded apps and domains, and focused secure fields are skipped. Detected credentials are redacted and the associated pixels are dropped. No detector is perfect, so exclude any app or domain whose content should never be retained.
</details>

<details>
<summary>Is the bundled llama.cpp server safe?</summary>

It's compiled from pinned source at build time, copied out of the app bundle before executing, bound to localhost only, and terminated when LokalBot quits.
</details>

<details>
<summary>Is it legal to record my calls?</summary>

LokalBot is a personal recorder, not a covert bot — and you're responsible for telling participants, the same as with any recorder. Recording-consent laws vary by place; when in doubt, announce it.
</details>

<details>
<summary>Known limitations</summary>

- Automatic Sparkle update checks are on by default for new installs and can be disabled in Settings.
- If system-audio tap creation fails, recording falls back gracefully to mic-only, with a warning.
- AAC encoding assumes Float32 tap/mic formats — verified on M-series hardware.
</details>

## For developers & agents

`lokalbot-cli` is embedded in the app bundle and gives coding agents **read-only** access to the local library. It supports `list`, `get`, `search`, and `path` from the shell, with JSON output by default. The same binary can run as a stdio **MCP server**:

- **Meeting access:** `list_meetings`, `get_meeting`, `search_meetings`, and `ask_library`.
- **Screen-memory access:** `search_screen`, `get_timeline`, `get_recent_activity`, `get_app_usage`, and `get_screenshot_detail`, behind a separate permission for today, the last seven days, or all retained history.
- **Privacy boundary:** screen tools return captured text and metadata, never decrypted pixels or screenshot paths. Out-of-scope ids appear missing.

LokalBot does not upload library content, but an MCP client such as Claude Desktop or Cursor may transmit tool inputs and results under its own privacy terms. Connect only clients you trust. `Scripts/build-mcpb.sh` packages the server as a one-click `LokalBot.mcpb` for GUI MCP clients.

```bash
lokalbot-cli search "auth refactor"
lokalbot-cli get latest --include summary
lokalbot-cli mcp        # stdio MCP: meeting tools + separately gated screen-memory tools
```

<div align="center"><img src="Assets/cli-demo.svg" alt="Animated terminal session: lokalbot-cli lists meetings as a table, searches transcripts for redis and returns JSON, then prints the latest meeting summary" width="720"></div>

Agent skill: [SKILL.md](.agents/skills/lokalbot-cli/SKILL.md) · architecture, headless flags, testing, and on-disk layout: [DEVELOPMENT.md](DEVELOPMENT.md)

[![skills.sh](https://skills.sh/b/stevyhacker/lokalbot)](https://skills.sh/stevyhacker/lokalbot/lokalbot-cli)

Claude Code users can install this access as a plugin: `/plugin marketplace add stevyhacker/lokalbot`, then `/plugin install lokalbot@lokalbot`. It adds the namespaced `/lokalbot:recall` command, the `lokalbot-cli` skill, and a stdio MCP server — details in [Distribution/claude-plugin/README.md](Distribution/claude-plugin/README.md).

## Build from source

You'll need **Xcode 16+** with a signing team, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and CMake (`brew install xcodegen cmake`).

```bash
git clone https://github.com/stevyhacker/lokalbot.git
cd lokalbot
xcodegen generate
open LokalBot.xcodeproj
```

Set your team under **Signing & Capabilities**, pick a scheme, and run:

| Scheme | Bundle id | Notes |
| --- | --- | --- |
| **LokalBot** | `me.dotenv.LokalBot` | production; Sparkle auto-update compiled in |
| **LokalBot Dev** | `me.dotenv.LokalBot.dev` | Sparkle compiled out; a distinct bundle id keeps its own permission grants, so running from Xcode never disturbs the released app |

The first build vendors pinned llama.cpp (`b10173`) via a pre-build phase; models download on first use, and macOS prompts for Microphone and System Audio on your first recording.

## Contributing & security

Issues and pull requests are welcome — see the [issue templates](.github/ISSUE_TEMPLATE) and [PR template](.github/PULL_REQUEST_TEMPLATE.md), and please run the unit tests before opening a PR ([DEVELOPMENT.md](DEVELOPMENT.md) has the commands). Security issues: report privately via [SECURITY.md](SECURITY.md) · usage help: [SUPPORT.md](SUPPORT.md).

If LokalBot is useful to you, a star helps other people find it.

## License

**GPLv3** — free software you can redistribute and modify ([LICENSE](LICENSE)). Because the GPL is copyleft, the "read every line, or build it yourself" guarantee is enforced by the license, not just promised.

## Acknowledgements

Built on [llama.cpp](https://github.com/ggml-org/llama.cpp), [IBM Granite Speech](https://huggingface.co/ibm-granite), [Parakeet](https://huggingface.co/nvidia), [Whisper](https://github.com/argmaxinc/WhisperKit), and [Qwen3-ASR](https://huggingface.co/Qwen) for transcription, [FluidAudio](https://github.com/FluidInference/FluidAudio) for diarization, [Sparkle](https://github.com/sparkle-project/Sparkle) for updates, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the project manifest. The Autocomplete feature's Cotyping engine shares its loop with [Cotabby](https://cotabby.app).

<details>
<summary>LokalBot for LLMs</summary>

LokalBot is a free, open-source (GPLv3) private AI work-memory app for macOS that runs on-device by default: a local LLM workhorse that keeps a memory of each workday. It records both sides of meetings without a bot, turns conversations and optional workday context into searchable, evidence-backed memory, then helps users recall, dictate, write, and automate. It is an alternative to Granola, Otter.ai, Rewind, Limitless, screenpipe, Superwhisper, and Hyprnote that runs transcription and summarization locally on Apple Silicon Macs (macOS 15+). Your microphone is captured as "Me" and the meeting app's system audio as "Them" via a Core Audio process tap, giving speaker-labeled transcripts without a meeting bot. Transcription engines include IBM Granite Speech 4.1, NVIDIA Parakeet, Whisper large-v3 turbo, and Qwen3-ASR, running on the Neural Engine via CoreML and MLX. Summaries are generated by a bundled llama.cpp runtime on localhost, or optionally by Ollama, any OpenAI-compatible server, or Apple Intelligence. There is no account, telemetry endpoint, or LokalBot cloud. Disclosed network paths are model/runtime downloads, optional update checks, remote inference origins the user explicitly approves, and network-capable Agent Mode commands the user explicitly approves. LokalBot also includes system-wide dictation, local Autocomplete powered by its Cotyping engine, opt-in Quick Recall, accessibility-first text context with optional encrypted visuals and local OCR fallback, evidence-backed citations, semantic search over meetings and captured text, fixed-scope local routines, scheduled Markdown/Obsidian/Logseq memory export, Memory Health diagnostics, chat over local memory, and a read-only CLI and MCP server for coding agents. External MCP clients may independently transmit tool inputs and results under their own privacy terms.

Guides: [local AI meeting notes on Mac](https://www.lokalbot.com/local-ai-meeting-notes-mac) · [offline meeting transcription](https://www.lokalbot.com/offline-meeting-transcription-mac) · [local transcription models compared](https://www.lokalbot.com/local-transcription-models-mac) · [open-source AI meeting notes](https://www.lokalbot.com/open-source-ai-meeting-notes) · [record both sides of a Mac meeting without a bot](https://www.lokalbot.com/record-both-sides-mac-meeting-without-bot)

</details>
