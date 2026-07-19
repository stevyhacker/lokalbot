# Demo film kit — the two money shots

_The 45–60 seconds of footage every launch post gets stronger with. Verified against this Mac on 2026-07-15: LokalBot **0.2.1** installed in /Applications, models already on disk (`WhisperModels/`, `LlamaRuntime/` in Application Support), mic + system-audio grants working (library has real meetings). No Little Snitch and no Zoom installed — both demos below are designed around that: **FaceTime** for the call (auto-detected), **`nettop`** for the network scene. nettop is the stronger choice anyway: it ships with every Mac, so every viewer can replicate the scene without buying anything._

Two deliverables:

| | Demo A — "The recap writes itself" | Demo B — "The whole cycle, offline" |
|---|---|---|
| Length | ~45 s | ~60 s |
| Story | Real 1:1 call, no bot, recap appears with the other person **named** | Record → transcribe → summarize with Wi-Fi off and a live network monitor |
| Used in | X/Reddit posts, landing hero, README | Show HN, r/LocalLLaMA, /enshittification-proof companion |

## Rig (once, ~10 min)

- **Focus on** (no notification pop-ins), Dark Mode, tidy menu bar, hide desktop icons: `defaults write com.apple.finder CreateDesktop false && killall Finder` (revert with `true` after).
- Record with **⌘⇧5 → Record Selected Portion**, a 16:9 region (e.g. 1920×1080). No voiceover — social autoplays muted; captions carry the story in the edit.
- LokalBot window ~1280×800, centered. Turn automatic update checks **off** in Settings — matters for Demo B's honesty.
- Keep every raw take. When someone on HN asks "is the demo edited?", the answer is a link to the uncut file.

## Demo A — "The recap writes itself"

### Pre-flight

1. **Calendar event first.** Create an event covering the call time, real title ("Q3 launch sync"), and invite **exactly one** attendee whose email resolves to a full name in your Contacts (e.g. Sarah). This is load-bearing: `SpeakerAutoNamer` (LokalBot/Services/SpeakerAutoNamer.swift) names the remote speaker **only** when there is exactly one remote speaker and exactly one remote non-declined attendee — a 1:1 with one invitee, or "Them" stays "Them". Don't add a second guest.
2. **One human, three minutes.** FaceTime them (Zoom isn't on this Mac; FaceTime is auto-detected). Solo fallback: your iPhone on a second Apple ID **in another room** so its audio only reaches the Mac through the call — mic bleed from the same room would land Sarah's lines on the *Me* track and ruin the labels.
3. Start recording from the **menu bar** for control (the HeroPanel with live timer + waveform is your opening shot).

### The call script (~90 s)

Engineered so a small local model produces a demo-grade recap: two explicit decisions, two owned action items with dates, one open question. Ad-lib around it, but land these lines:

> **You:** Quick one — we need to lock the beta date.
> **Sarah:** I can have the release notes drafted by Thursday.
> **You:** Then let's ship the beta Friday morning. Decision made.
> **Sarah:** Agreed. I'll also email the pilot customers today.
> **You:** One open question — do we raise the price at GA, or keep it flat through Q3?
> **Sarah:** Park it for Monday. Send me the usage numbers before then.
> **You:** Deal — I'll pull the numbers tomorrow.

### Shot beats

1. **0–5 s** — menu bar → start recording; timer + waveform visible.
2. **5–15 s** — the FaceTime window. Caption: *"No bot joined. My mic is 'Me'. A Core Audio tap on FaceTime is 'Them'."*
3. **15–25 s** — hang up → processing state.
4. **25–40 s** — **the money frame:** recap with TL;DR, decisions, action items; transcript labeled with the attendee's actual name. Hold ≥3 s on *"Sarah: release notes by Thursday."*
5. **40–45 s** — click a search hit → audio replays from that exact second.

Retakes are cheap: delete the meeting, new calendar event, go again.

## Demo B — "The whole cycle, offline"

Split screen: LokalBot left, Terminal right (font bumped ⌘+ ×4).

### Terminal scene

```bash
# live, per-process, ships with every Mac:
nettop -p LokalBot -p llama-server
```

Expected honest output: **loopback only** — `127.0.0.1 ↔ 127.0.0.1` rows for the bundled llama-server (it binds localhost with a per-run auth token; LokalBot/Engines/LlamaServer.swift). Caption that, don't hide it: *"The only 'network' is the app talking to its own model server on localhost."* It reads stronger than an empty screen because it shows you're not filtering anything out.

### Shot beats

1. **0–8 s** — caption: *"Full cycle: record → transcribe → summarize. Watch the network column."* nettop already running.
2. **8–20 s** — a short call records (fresh take, not Demo A's).
3. **20–25 s** — hang up, then **click Wi-Fi off in the menu bar.** Linger one beat on the empty Wi-Fi icon. (Order matters: Wi-Fi off *before* processing, *after* the call — FaceTime needs the network; the pipeline doesn't.)
4. **25–45 s** — processing runs offline → transcript → recap appears. nettop stays loopback-only.
5. **45–55 s** — closer in Terminal:
   ```bash
   lsof -i -nP | grep -iE 'lokalbot|llama-server'
   ```
   Only 127.0.0.1 lines. Caption: *"Nothing external. Verify on your own Mac — same commands."*
6. **55–60 s** — end card: **lokalbot.com — GPLv3 — no account.**

### Honesty rails

- One continuous take from hang-up to recap; cut for pacing only in the social edit, publish the raw alongside.
- If anything external ever appears in nettop mid-take: stop, investigate, fix, refilm. Never publish around it — the entire brand is that this footage can't exist for anyone else.

## Files

- Masters: `Assets/demos/demo-a-recap.mov`, `Assets/demos/demo-b-offline-cycle.mov`, plus `*-raw.mov` uncut takes (large files — keep out of git or use Releases/LFS; link raws from posts).
- Exports per post: H.264 MP4 ≤50 MB for X; a 10–15 s GIF excerpt of Demo A beats 4–5 is the future README hero replacement.
