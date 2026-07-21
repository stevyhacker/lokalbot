# LokalBot — Growth Plan

_Date: 2026-07-21. Companion to `product-roadmap.md`. The premise: skip the generic open-source playbook (that's a checklist at the end, not a strategy) and build growth mechanics only LokalBot can run — each one exploits a property competitors structurally cannot copy: cloud notetakers can't go silent on the network, bot-based tools can't be invisible in the call, and closed-source apps can't invite an audit._

## The seven mechanics

### 1. The standing bounty: "Catch LokalBot phoning home"

**Exploits: the privacy claim is falsifiable. Cloud competitors cannot run this play at any price.**

Turn the README's Little Snitch paragraph from a defensive FAQ into an offensive spectacle: a permanent, public challenge — *catch the built-in processing path making an outbound connection during record → transcribe → summarize, win the bounty and a place on the wall.* Even a modest pot ($500–1000) works, because the money isn't the point; the dare is.

- A `web/bounty.html` page with precise rules (built-in backend, models pre-downloaded, update checks off — the same conditions the README already states), a hall-of-fame for anyone who finds *any* undisclosed network path, and instructions for capturing evidence.
- Every failed attempt is a third-party endorsement someone else publishes for you. A successful catch is a free security audit plus an honest disclosure post — which, for this audience, also builds trust.
- This is the launch asset: "Show HN: I'm paying anyone who can catch my meeting transcriber making a network request" is a far stronger headline than a feature list, and it *is* the product's thesis in one sentence.
- Cost: bounty pot + rigor in the rules (get the disclosed-exceptions list airtight first — Sparkle, model downloads, approved origins are already documented in PRIVACY.md).

**Done when:** the page is live, the challenge has been posted, and at least one outsider has published an attempt.

### 2. Local Wrapped — the shareable artifact computed off-cloud

**Exploits: the app sees a year of someone's work life and can prove it never left the Mac.**

Spotify Wrapped mechanics are the most reliable consumer viral loop that exists, and every cloud tool that copies it has to mumble past the "we mined your data" part. LokalBot gets the loop *and* the counter-positioning: **"Computed on my Mac. Shared by me, not by a server."**

- A locally rendered, screenshot-ready card: hours of meetings transcribed, words dictated, Cotyping completions accepted, busiest day, longest meeting survived — and the kicker line: **"Cloud equivalent: ~$34/mo across Otter + Superwhisper + Rewind. Paid: $0."** All computable today from `SQLiteDatabase` + the meetings library; rendering is a SwiftUI view exported to PNG.
- Ship a small always-available version first (a "your stats" card in Today with a share button — the savings counter alone is a flex people screenshot), then the full year-in-review in **early December**, timed to Wrapped season when the format is ambient.
- Nothing leaves the Mac; the user shares an image or doesn't. The invariant is the punchline, printed on the card.

**Done when:** a stats card exists with one-tap image export, and the December build ships a year-in-review.

### 3. The switch kit — destroy the exit cost of every competitor

**Exploits: cloud notetakers hold users hostage via their archives; LokalBot's file-based library can eat them.**

Everyone deciding to leave Otter/Granola/Limitless faces the same wall: years of meetings stuck in someone's cloud. Build importers for their export formats (Otter bulk export, Granola, Limitless/Rewind takeout) that land straight into `meetings/` + FTS + embeddings — searchable next to new local recordings.

- One importer per competitor, plus a matching page: *"Leave Otter. Take your meetings with you."* These rank for high-intent exit queries ("export otter transcripts", "granola export") that competitors' own help docs currently monopolize.
- **Churn-jack the news cycle.** Keyword-watch Reddit/X/HN for the recurring anger moments — a price hike, the next Rewind-style cloud pivot, and the evergreen genre of *"an Otter bot joined our call and recorded us after the employee left"* incident posts. Each one gets a same-day, genuinely helpful reply and, for the big ones, a dedicated response page. The `enshittification-proof.html` page already exists as the ideological landing zone; importers make it actionable within the hour of someone's rage-quit.
- The GPL angle closes the loop: switching *to* LokalBot is the last migration they'll need, because a rug-pull fork is legally impossible to close-source.

**Done when:** at least the Otter importer ships and each importer has its exit-intent landing page.

### 4. Become the benchmark Mac reviewers run

**Exploits: reproducible local-AI numbers on Apple Silicon — content nobody else produces and reviewers need every chip cycle.**

Every M-series launch, YouTube reviewers scramble for "AI performance" tests and end up timing Ollama token counts. Give them a one-command, camera-friendly benchmark: `lokalbot-cli benchmark` — transcription realtime-factor, summary tokens/s, embedding throughput on a bundled sample meeting, with a clean printed scorecard.

- A public leaderboard (repo or page) seeded with the numbers already in the README (M4 Max: Parakeet ~190× realtime, ~100 tok/s summaries), accepting submissions by PR — UGC that is also stars and contributors.
- Pitch it directly to the Mac-review circuit before the next chip launch: "the meeting-transcription benchmark" is a more relatable AI test than synthetic tokens/s, and every video that runs it shows the app by name.
- Cost is small: the timing hooks exist (`Benchmarks/`, the headless harness); this is packaging plus a scorecard printer.

**Done when:** the subcommand exists, the leaderboard has third-party submissions, and one reviewer has used it on camera.

### 5. The IT-approval kit — bottom-up enterprise without an enterprise

**Exploits: security teams are actively banning cloud notetaker bots; a local-only recorder is the one thing they can approve.**

The trend is real and accelerating: companies block Otter/Fireflies bots from calls and prohibit employees pasting meeting audio into cloud tools. Every such ban strands employees who still want notes — and one approved employee converts a whole company, for free.

- A downloadable **security-review packet**: architecture one-pager, complete network-egress inventory (the PRIVACY.md disclosure list, restated for a reviewer), data-at-rest details (AES-GCM, Keychain, retention), GPL auditability, and the bounty (§1) as evidence of confidence. Written for the person filling in the vendor-assessment spreadsheet.
- MDM/Jamf deployment notes (it's a signed, notarized, sandbox-free Developer ID app — document the PPPC profile for Mic/Screen Recording/Accessibility so IT can pre-grant).
- Landing page: *"The meeting notetaker your security team will approve."* It ranks for the queries IT people and blocked employees actually type.

**Done when:** the packet is downloadable and one org has deployed via MDM.

### 6. Confidentiality verticals — the users who legally cannot use the competition

**Exploits: for privileged conversations, local-only isn't a preference, it's the only compliant option.**

Lawyers (privilege), therapists and physicians (confidentiality), journalists (source protection), HR (investigations), and EU workplaces (GDPR; German works councils routinely veto cloud recording outright). Cloud notetakers are disqualified at the policy level in all of these — LokalBot competes in these niches *unopposed*.

- One landing page per vertical in the existing `web/` template: "AI meeting notes for lawyers — the audio never leaves your Mac," same for therapy notes, source-protected interviews, HR conversations. Each states the compliance logic plainly and honestly (including what LokalBot does *not* claim, e.g. it is not itself a HIPAA-certified system — it's an on-device tool, which is precisely why the data-processor question disappears).
- A German-language page targeting *"DSGVO-konforme Meeting-Transkription"* and the works-council (Betriebsrat) angle — a wedge where the entire cloud category is often contractually forbidden.
- These communities are small, dense, and high word-of-mouth: one respected lawyer or journalist advocating in their professional forum outperforms any general launch. Seed each page into the profession's own watering holes (legal-tech newsletters, Freedom of the Press Foundation orbit, therapist tech groups) rather than general tech channels.

**Done when:** four vertical pages + the German GDPR page are live and each has been introduced into one professional community.

### 7. Arm the in-meeting moment

**Exploits: every meeting a user attends contains 2–15 perfectly qualified prospects who just watched the product work.**

The conversion moment already happens organically: the user shares a recap or references the transcript, someone asks *"wait, which bot was that? I didn't see a bot."* — and the answer ("there is no bot, it runs on my Mac, it's free") is the entire pitch. The hack is reducing that answer to one action:

- After a recap is exported/copied, a one-time nudge offers an **opt-in, default-off** provenance footer — *"Summarized locally by LokalBot — no bot was in this call · lokalbot.com"*. Every pasted recap becomes an impression in front of exactly the people who were in the room.
- A share-ready one-liner in the app ("how I take notes without a bot" + link) for answering the question in chat without typing the pitch.
- Hard line, stated in the doc because it's brand-critical: LokalBot never messages meeting participants itself, and the footer never turns on without explicit consent. The no-bot product must never behave like a bot.

**Done when:** the footer + nudge ship (off by default) and the recap-share path is one tap.

---

## Table stakes (do them, but they're a checklist, not the plan)

Homebrew cask (`livecheck` off the Sparkle appcast) · Show HN / r/LocalLLaMA / r/macapps / Product Hunt launches, spaced, maintainer on comment duty · AlternativeTo + awesome-lists · remaining "vs" and "alternative" SEO pages (Otter, Fireflies, Limitless, Fathom) · `web/llms.txt` mirroring the "LokalBot for LLMs" block · MCP registry + directory submissions for the `.mcpb` · per-release GIF + notes ritual.

## Measurement without telemetry

Public-signal scoreboard only, refreshed weekly by script: GitHub release download counts (installs proxy), stars + repo-traffic snapshots, privacy-preserving site analytics on lokalbot.com, and server-side counting of appcast fetches (an active-installs proxy using requests that already occur — disclose in PRIVACY.md). Every mechanic above must be attributable to a spike in this scoreboard or it gets cut. App telemetry stays forbidden; its absence is mechanic §1's ammunition.

## Sequencing

1. **First:** §1 bounty (cheap, pure leverage, and it *is* the launch headline) + measurement scripts + the table-stakes checklist items that take an afternoon each (cask, listings).
2. **Launch season:** Show HN built around the bounty; r/LocalLLaMA built around the model stack; then §4 benchmark packaging so the leaderboard exists before the next Apple chip event.
3. **Next:** §3 Otter importer + exit pages, and the churn-jack keyword watch (starts paying immediately and forever).
4. **Then:** §5 IT packet and §6 vertical pages (writing-heavy, code-light — batchable).
5. **December:** §2 Local Wrapped, timed to Wrapped season. The always-on stats card and §7 footer ship whenever a release window allows before that.

**Roadmap dependencies:** the consent-default `.ask` fix (roadmap item 2) should precede any big launch — for a product whose story is trust, silent-auto-record is the one comment thread that can sink it — and Auto-model onboarding (item 5) protects launch-spike conversion from ten-minute first-recap waits.
