# LokalBot — Reddit launch/marketing posts

Tailored, ready-to-post copy for marketing LokalBot across relevant subreddits, plus the etiquette that keeps these posts from getting removed. Refreshed to include the features that landed since the original [r/LocalLLaMA post](https://www.reddit.com/r/LocalLLaMA/comments/1ukhpnl/lokalbot_fully_local_macos_app_meetings/) — most notably **system-wide dictation**, **IBM Granite Speech 4.1** as the recommended ASR, **neural diarization**, **semantic + chat search**, and a bigger local-model catalog.

> **On the original post:** reddit.com is unreachable from the tooling used to draft this, so the "base" post below is reconstructed from the current README + website voice rather than copied verbatim. It reads as a natural *update* to the original announcement.

**Canonical links to drop in every post**
- Repo: <https://github.com/stevyhacker/lokalbot>
- Download (signed `.dmg`): <https://github.com/stevyhacker/lokalbot/releases>
- Site: <https://www.lokalbot.com>

---

## What's new since the original post (call these out)

Lead with 2–3 of these depending on the audience. This is the "and it got better" hook.

- **Dictation — system-wide voice typing.** Hold **⌥ Space**, talk, release: transcribed on-device and pasted at the cursor. Pauses your music first; audio is deleted right after transcription. Opt-in.
- **IBM Granite Speech 4.1** is the new recommended transcription engine (higher accuracy). Parakeet TDT v3 still there for ~190× realtime speed; Whisper large-v3 turbo for 99 languages; Qwen3-ASR for hard recordings — 8 models across 5 engines total.
- **Neural diarization** ("Split *Them* by speaker") via FluidAudio's pyannote-community-1 pipeline — relabels multi-person calls Them 1 / Them 2 / …
- **Semantic search**, not just keyword — transcript/summary chunks embedded with Qwen3-Embedding on a second local llama-server, brute-force cosine, instant at personal scale.
- **Chat with your meetings** — a small on-device ReAct agent answers "what did we decide?" grounded in your library, reusing the same local model as summaries.
- **Bigger, better model catalog** — Qwen 3.6 · 35B-A3B (MoE) recommended for summaries, Gemma 4 · E4B for Cotyping (runs in-process via libllama for low latency), LFM2.5 tiers, plus in-app Hugging Face GGUF browse.
- **Day timeline + digests + "ask your day"** — a private, opt-in timeline of apps/meetings and a one-click daily digest.
- **Robustness** — AirPods/USB device switches mid-call no longer truncate the recording; browser meetings (Meet, Jitsi, Whereby) detected from the window title; signed distribution + Sparkle in-place updates.
- **Agent CLI** — `lokalbot-cli` gives coding agents read-only access to your meeting library (`list`/`get`/`search`/`path`).

---

## Reddit etiquette (read before posting anything)

Getting removed or shadow-flagged is the default outcome for tool self-promo. Avoid it:

1. **Disclose you're the author.** "I built this" / "I've been working on this." Every post below is written first-person for exactly this reason. Undisclosed self-promo is a bannable offense on most of these subs.
2. **Don't blast them all in one day.** Space posts out over **2–4 weeks**, ideally one sub every few days. Same link to many subs in a short window trips Reddit's site-wide spam filter and can shadowban the account.
3. **Read each sub's rules + check for a self-promo / "what are you working on" thread first.** Some subs (r/productivity, r/apple, r/therapists, r/consulting) forbid standalone promo and *only* allow it in a weekly thread or not at all. Rules below are best-effort — **verify current rules**, they change.
4. **Lead with value, not a pitch.** The strongest hook LokalBot has is *"don't trust me, verify it with Little Snitch / `lsof`."* Use it. It reframes the post from "buy my thing" to "here's a claim you can check."
5. **Be present in the comments.** Answer the "how is this different from Hyprnote/Granola/Superwhisper?" questions honestly. Engagement in the first hour drives the post.
6. **Free + open-source + no-account up top.** It's the single best defense against "this is just an ad."
7. **One image/GIF beats three paragraphs.** Attach a screenshot or the demo GIF where the sub allows image posts.
8. **Have some karma/age on the account** before posting to the strict subs, or the automod eats it.

**Suggested sequencing:** r/macapps → r/LocalLLaMA (update) → r/LocalLLM / r/ollama → r/privacy → r/opensource → r/macOS → r/selfhosted → r/Swift → dictation-alternative subs → niche/professional last.

---

## 1. r/LocalLLaMA — the refreshed base post (update to the original)

*Angle: the local-model stack. This crowd cares about which models, running in-process vs. server, the Neural Engine, and BYO-model. Post as an update to the original.*

**Title:** LokalBot update — fully on-device Mac meeting notes now with system-wide dictation, Granite Speech 4.1, diarization, and a bigger local-model catalog

**Body:**

A while back I posted LokalBot here — a 100% on-device macOS app that records both sides of a call, transcribes, and summarizes without anything leaving the Mac. It's grown a fair bit since, so here's an update.

The whole thing still runs on local models on Apple Silicon. The only network call it *ever* makes is the one-time model download from Hugging Face; the bundled llama.cpp server (pinned `b9844`) binds to localhost only. Don't take my word for it — run Little Snitch or `lsof -i -nP | grep LokalBot` through a full record → transcribe → summarize cycle and watch it stay flat.

What's new:

- **Dictation.** Hold ⌥ Space anywhere, talk, release — transcribed on-device by your chosen ASR engine and pasted at the cursor. Prewarms the model when the shortcut is armed so short dictations start instantly.
- **Transcription is now 8 models across 5 engines.** Recommended default is **IBM Granite Speech 4.1**; **Parakeet TDT 0.6B v3** for ~190× realtime, **Whisper large-v3 turbo** for 99 languages, **Qwen3-ASR** (MLX) for harder recordings.
- **Neural diarization** via FluidAudio (pyannote-community-1) splits multi-person calls into Them 1 / Them 2 / … The mic track is always "Me," the system-audio process tap is "Them" — so you get speaker labels for free even before diarization.
- **Summaries** run on the built-in llama.cpp runtime (or Ollama / any OpenAI-compatible server / Apple Intelligence). Recommended model is **Qwen 3.6 · 35B-A3B** (MoE); the catalog also has Gemma 4, LFM2.5 MoE, smaller Qwen tiers, plus an in-app Hugging Face GGUF browser.
- **Semantic search** — chunks embedded with Qwen3-Embedding 0.6B on a second local llama-server, cosine over vectors in SQLite. Plus **chat with your meetings**: a small ReAct agent grounds answers in your library using read-only tools.
- **Cotyping** (inline autocomplete) decodes a dedicated model **in-process via libllama** for latency, recommended Gemma 4 · E4B.

It's free, GPLv3, no account, no telemetry. Source and signed `.dmg`: <https://github.com/stevyhacker/lokalbot>

Requirements: Apple Silicon (M1+), macOS 15+. Happy to answer anything about the model choices or the Core Audio tap plumbing.

---

## 2. r/macapps — Mac-app discovery

*Angle: it's a free, polished Mac app that does a lot. This sub loves new native apps and is tolerant of "I made this." Attach the hero GIF.*

**Title:** I built LokalBot — free, open-source Mac app for private meeting notes, dictation, and inline autocomplete (100% on-device, no account)

**Body:**

LokalBot is a free Mac app I've been building that handles a chunk of your workday without sending anything to the cloud — no account, no subscription, no API keys.

What it does:

- **Meeting notes.** Auto-detects Zoom, Teams, Meet, Slack, Webex, FaceTime, records *you* and *them* on two synced tracks, and writes a TL;DR with decisions and action items the moment the call ends. Speaker labels come for free.
- **Dictation.** Hold ⌥ Space in any app, talk, release — it types what you said. Pauses your music first, deletes the audio after.
- **Cotyping.** Ghost-text autocomplete as you type in almost any app; press Tab to accept. Opt-in, skips password fields.
- **Search everything you've heard.** Full-text *and* meaning-based search across transcripts and summaries; click a hit to play from that exact second.
- **Day timeline.** An optional, private timeline of where your time went, with a one-click daily digest.

Everything runs on-device on Apple Silicon. The only network call is a one-time model download; after that it works fully offline. It's open source (GPLv3), so if you don't believe the privacy claim you can read the network code or watch `lsof` stay silent through a whole meeting.

Free, signed `.dmg`: <https://github.com/stevyhacker/lokalbot/releases> · Requires Apple Silicon + macOS 15+.

Would love feedback on what's missing.

---

## 3. r/LocalLLM  (and cross-post angle for r/ollama)

*Angle: same as LocalLLaMA but for the sibling communities. For r/ollama, foreground that LokalBot can point its summaries/chat at your existing Ollama instance.*

**Title (r/LocalLLM):** A local-first Mac app that puts your on-device models to work on real tasks — meetings, dictation, autocomplete, search

**Title (r/ollama):** LokalBot: private Mac meeting notes + dictation that can run summaries/chat through your local Ollama

**Body:**

Most of us run local models and then… mostly chat with them. LokalBot is a free Mac app I built to point them at everyday work instead, entirely on-device:

- **Meetings** → records both sides, transcribes (Granite Speech / Parakeet / Whisper / Qwen3-ASR), diarizes, and summarizes.
- **Dictation** → hold ⌥ Space, speak, it types on-device.
- **Cotyping** → inline autocomplete from a dedicated model running in-process via libllama.
- **Chat + semantic search** over your whole meeting library, grounded by a small ReAct agent.

For the summary/chat backend you can use the **bundled llama.cpp runtime** (pick any GGUF, browse Hugging Face in-app), **Ollama**, **any OpenAI-compatible server** (LM Studio, vllm-mlx…), or **Apple Intelligence**. So your existing local stack just plugs in — point it at `localhost:11434` and go.

Nothing leaves the Mac unless *you* point it at a remote endpoint. Bundled runtime is localhost-only; verify with `lsof -i -nP | grep LokalBot`.

Free, GPLv3, Apple Silicon + macOS 15+: <https://github.com/stevyhacker/lokalbot>

---

## 4. r/privacy  (and r/PrivacyGuides with a softer, less "launch" tone)

*Angle: the verifiable no-network claim, open source, no account/telemetry, on-disk encryption. This audience is allergic to marketing — keep it factual and lead with the check.*

**Title:** A meeting-notes / dictation app for Mac whose privacy claim you can actually verify with Little Snitch (open source, on-device)

**Body:**

Every notetaker says it "cares about privacy." I got tired of that being unverifiable, so I built LokalBot to make the claim checkable.

It records meetings, transcribes, summarizes, does dictation and inline autocomplete — all with on-device models on Apple Silicon. The design invariant is that **nothing leaves the Mac**: no account, no telemetry, no cloud calls.

How you verify it rather than trust it:

- Run **Little Snitch** or `lsof -i -nP | grep LokalBot` through a full record → transcribe → summarize cycle. Zero connections.
- The only outbound call the app ever makes is a **one-time model download** from Hugging Face; after that it's fully offline.
- The bundled llama.cpp server **binds to localhost only**.
- It's **open source (GPLv3)** — read the network code yourself.
- Optional screenshots (day timeline, off by default) are **AES-GCM encrypted** with a per-install Keychain key and auto-delete after 14 days. Password fields and excluded apps are never read. Dictation audio is deleted right after transcription.

No account to create, nothing to opt out of, no data-processing agreement to chase — there's no third party in the loop.

Source + signed build: <https://github.com/stevyhacker/lokalbot>. Apple Silicon, macOS 15+.

> *r/PrivacyGuides note:* check the rules — it may need to go in a designated thread, and they prefer "here's a tool + how to verify it" over "I built this." Drop the first-person launch framing and keep the verification bullets.

---

## 5. r/selfhosted — local-first / own-your-data

*Angle: no server to run, but the ethos is identical — your data on your hardware, no SaaS. Acknowledge up front it's a local app, not a server, so you don't get "this isn't self-hosting."*

**Title:** LokalBot — local-first meeting notes + dictation for Mac. No server, no SaaS, no account; your data never leaves the machine

**Body:**

Not self-hosted in the "spin up a container" sense — it's a Mac app — but it's the same spirit this sub is about: your conversations, transcripts, and summaries live on *your* hardware, processed by models running on *your* machine, with no vendor account and nothing phoned home.

- Records both sides of calls → local transcription → local summaries, all on Apple Silicon.
- Dictation and inline autocomplete, also on-device.
- Data is plain files on disk: `meetings/YYYY/MM/dd-slug/` with `mic.m4a`, `system.m4a`, `transcript.{json,md}`, `summary.md`, plus a SQLite index. Fully greppable, yours to back up, no lock-in.
- Summaries/chat can run on the bundled llama.cpp runtime **or** you can point them at your own **Ollama** / OpenAI-compatible endpoint on the LAN.
- Read-only `lokalbot-cli` (`list`/`get`/`search`/`path`, JSON out) so you can script against your own library.

No cloud dependency, no subscription. GPLv3. Verify the no-network claim with `lsof -i -nP | grep LokalBot`.

<https://github.com/stevyhacker/lokalbot> — Apple Silicon, macOS 15+.

---

## 6. r/opensource — the code & license story

*Angle: GPLv3, architecture, buildable, contributable. This crowd wants to know how it's built and whether the openness is real.*

**Title:** LokalBot — GPLv3 macOS app for on-device meeting notes, dictation, and autocomplete. "Read every line, or build it yourself" is enforced by the license, not just promised

**Body:**

LokalBot is a fully open-source (GPLv3) macOS app for private, on-device AI: meeting recording + transcription + summaries, system-wide dictation, inline autocomplete, semantic search, and a day timeline. No account, no telemetry, no cloud.

For this sub, the interesting parts are how it's put together:

- **Audio:** mic via `AVAudioEngine` ("Me"), the other side via a **Core Audio process tap** on the meeting app's PID ("Them") → free diarization, refined by FluidAudio's pyannote pipeline.
- **Inference:** bundled **llama.cpp** (pinned `b9844`) as a localhost server for summaries/chat; **in-process libllama** for low-latency autocomplete; WhisperKit/MLX/sherpa-onnx for ASR.
- **Index:** system SQLite + FTS5 for keyword search, plus vector embeddings (Qwen3-Embedding) for semantic search — no external DB dependency.
- **Build:** Xcode project is generated by **XcodeGen** from a `project.yml` manifest; `git clone && xcodegen generate && open` and you're running it.

Because it's copyleft, any distributed derivative has to ship source too — the "you can audit it" guarantee is enforced, not just a promise. Issues and PRs welcome.

<https://github.com/stevyhacker/lokalbot> · macOS 15+, Apple Silicon.

---

## 7. r/macOS — general Mac users

*Angle: a genuinely useful native Mac app. Less jargon than the LLM subs. Emphasize menu bar, native feel, "just works." Check the rules — some weeks self-promo is restricted; "I made this" is usually tolerated.*

**Title:** I made a free Mac app that records your meetings and writes the notes — entirely on your Mac, no account or cloud

**Body:**

I wanted meeting notes without handing my calls to a cloud service, so I built LokalBot. It lives in the menu bar, notices when you're on a call (Zoom, Teams, Meet, Slack, Webex, FaceTime), records both sides, and when the call ends it writes a clean summary — TL;DR, decisions, action items — with a speaker-labeled transcript.

It grew into a bit more than notes:

- **Dictation** — hold ⌥ Space in any app and just talk; it types for you (and pauses your music while you do).
- **Autocomplete** — optional ghost-text suggestions as you type, Tab to accept.
- **Search** — find any word you've ever heard across your meetings and jump to that second of audio.
- **Day timeline** — an optional private view of where your time actually went.

The whole thing runs on-device on Apple Silicon — the only network call is a one-time model download, then it's fully offline. It's free and open source. Requires macOS 15+ and an M-series Mac.

<https://github.com/stevyhacker/lokalbot/releases>

---

## 8. r/productivity — the whole-workday framing

*Angle: one app that covers meetings + writing + dictation + time tracking. STRICT self-promo rules — most likely this belongs in their weekly share thread, not a standalone post. Keep it about the workflow, mention the tool once.*

**Title:** My setup for capturing meetings, notes, and where my time goes — without a stack of cloud subscriptions

**Body:**

Sharing a workflow that replaced ~three cloud tools for me. The tool is a free, open-source Mac app I built (LokalBot), but the point is the workflow — everything runs locally, so there's no per-seat subscription and nothing leaves the machine.

- **Meetings:** it records both sides of a call and auto-writes the recap (decisions + action items) when the call ends. I stopped taking live notes and just listen.
- **Writing:** dictation on a single key-hold (⌥ Space) for anything longer than a sentence; inline autocomplete for the repetitive stuff.
- **Recall:** everything I've heard is searchable — including "what did we decide about X?" answered from my own meetings.
- **Time:** an optional day timeline shows where the hours actually went, with a one-click end-of-day digest.

The unlock for me was that it's all in one place and all local — no juggling Otter + a dictation app + a time tracker, and no privacy tradeoff.

If links are allowed here: <https://github.com/stevyhacker/lokalbot>. Happy to share more of the config in the comments.

> *Etiquette:* r/productivity usually removes standalone tool posts. Prefer their **weekly "what are you using" / self-promotion thread**, or frame purely as a workflow with the tool as a footnote.

---

## 9. r/Swift / r/iOSProgramming — the "how it's built" show-and-tell

*Angle: developers want the engineering. This is a legit "I shipped this, here's the interesting tech" post. r/iOSProgramming covers all Apple-platform dev including macOS.*

**Title:** Shipped a macOS app that runs LLMs + ASR fully on-device — Core Audio process taps, in-process llama.cpp, XcodeGen. Source is GPLv3

**Body:**

Sharing LokalBot in case the internals are useful — it's an open-source macOS app doing on-device meeting transcription/summaries, dictation, and inline autocomplete, and a few pieces were fun to build:

- **Capturing "the other side" of a call:** a **Core Audio process tap** on the meeting app's PID → aggregate device → AAC, alongside an `AVAudioEngine` mic tap. Re-installs the tap on `AVAudioEngineConfigurationChange` so AirPods/USB switches mid-call don't truncate the recording, and encodes off the real-time IOProc thread.
- **Two inference paths for llama.cpp:** a localhost `llama-server` (pinned `b9844`) for summaries/chat, and **in-process libllama** for low-latency ghost-text autocomplete — the app copies the vendored server out of Resources rather than executing from inside the bundle.
- **Search without a dependency:** system SQLite + FTS5 for keyword, plus a second llama-server instance running an embedding model for brute-force-cosine semantic search.
- **Testability:** the app binary doubles as a headless harness (`--process`, `--search`, `--record`, `--chat`), and the meeting-detection/autocomplete logic is decomposed into small pure policy types so they unit-test without AX or audio.
- **Project:** `.xcodeproj` is generated by **XcodeGen**; App Sandbox is intentionally off because Core Audio process taps don't work sandboxed (Developer ID + notarization instead of the App Store).

Code (GPLv3): <https://github.com/stevyhacker/lokalbot>. Happy to go deeper on any of it.

---

## 10. Dictation-alternative angle — r/superwhisper, and as a secondary hook anywhere ASR/dictation people gather

*Angle: a free, open-source, local alternative to paid dictation tools (Superwhisper, Wispr Flow). Be respectful in a competitor's sub — lead with "another local option," not trash-talk.*

**Title:** A free, open-source local dictation option for Mac (bundled into a bigger on-device app) — hold ⌥ Space, speak, it types

**Body:**

If you're into local dictation, LokalBot has a dictation mode that might be worth a look — it's free and open source (GPLv3). Hold ⌥ Space in any app, talk, release, and it pastes the text at your cursor. It pauses whatever media is playing first, and the audio is deleted right after transcription. All on-device on Apple Silicon.

The ASR is your pick: **Granite Speech 4.1**, **Parakeet** (fast), **Whisper large-v3 turbo** (99 languages), or **Qwen3-ASR** — the same engine gets prewarmed when the shortcut is armed so short dictations start instantly.

The catch/bonus depending on your view: dictation is one feature of a larger on-device app that also does meeting notes and inline autocomplete, so it's not a single-purpose dictation tool. But if you want local dictation with no subscription and code you can read, it's here: <https://github.com/stevyhacker/lokalbot>

Apple Silicon, macOS 15+.

---

## Secondary / niche subreddits (angle + short pitch)

Smaller reach or stricter rules — post these later, and only after the account has traction.

### r/ClaudeAI · r/ChatGPTCoding · r/cursor — the coding-agent angle
*Lead: give your agent read-only access to your own meetings.*

**Title:** I gave my coding agent read-only access to my meeting notes — local CLI + skill, everything on-device

**Body:** LokalBot ships `lokalbot-cli` (`list`/`get`/`search`/`path`, JSON out) and a bundled agent skill, so Claude Code / Cursor / any agent can answer "what did we decide with the client last week?" straight from your local meeting library — no cloud, no account. The meetings themselves are recorded, transcribed, and summarized on-device. Free, GPLv3: <https://github.com/stevyhacker/lokalbot>

### r/degoogle · r/DataHoarder — own-your-data
*Lead: your meetings as plain files you keep forever, no SaaS.* Recycle the r/selfhosted body, emphasize the on-disk `meetings/…/*.md` + SQLite layout and that there's no account holding your data hostage.

### r/artificial · r/ArtificialInteligence — general AI
*Lead: a concrete, shipped example of "AI that runs entirely on your own device."* Recycle the r/macapps body, but open with the on-device framing since this crowd is thinking about cloud AI by default. Lower signal-to-noise; expect more "does it work on Windows?" (it doesn't — Apple Silicon only).

### Professional niches — post with extra care, rules are strict
- **r/consulting**, **r/Lawyertalk / r/LawFirm**, **r/therapists / r/psychotherapy**: the pitch is *confidential/privileged/clinical calls that legally shouldn't touch a cloud vendor.* These subs heavily restrict promotion and are protective — **do not** drop a launch post. If you engage at all, do it as a genuine reply in an existing "how do you handle notes / is X notetaker HIPAA-safe?" thread, disclose you built it, and frame it as "there's no third-party processor because nothing is uploaded — you can verify with Little Snitch." Read rules first; many will still remove it.
- **r/Zoom**, **r/microsoftteams**: niche but on-topic for "record + summarize my calls locally." Low volume.

---

## Reusable snippets

**The verification hook (drop into any post):**
> Don't take my word for the privacy claim — run Little Snitch or `lsof -i -nP | grep LokalBot` through a full record → transcribe → summarize cycle and watch the network graph stay flat. It's open source, so you can read the network code too.

**The one-liner:**
> LokalBot — free, open-source Mac app for private, on-device meeting notes, dictation, and inline autocomplete. No account, no cloud, no subscription. Apple Silicon + macOS 15+.

**Standard FAQ answers for the comments:**
- *How is this different from Granola/Otter/Hyprnote?* Those process your audio in the cloud; LokalBot runs the models on your Mac and uploads nothing — and it's open source so you can verify it. Comparison pages: lokalbot.com/lokalbot-vs-granola, /lokalbot-vs-hyprnote.
- *Windows/Linux?* Apple Silicon Macs only (M1+), macOS 15+ — it leans on the Neural Engine, MLX, and Metal.
- *Is it really free?* Yes. No account, no subscription, no telemetry. Full source on GitHub; you can build it yourself.
- *Does it join my calls as a bot?* No. It records the audio locally on your machine — no bot in the meeting, no participant to consent to.
