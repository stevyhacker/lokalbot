# LokalBot — Growth Plan

_Date: 2026-07-21. Companion to `product-roadmap.md` (which covers what to build). This covers how people find out the product exists. Grounded in the actual constraints: free, GPLv3, no telemetry, no cloud, Apple Silicon + macOS 15+ only, one maintainer, distribution outside the App Store._

## The shape of the problem

LokalBot has no paid acquisition budget, no sales motion, and — by architectural invariant — no telemetry to run funnels on. That rules out most of the standard growth playbook and leaves the channels where free, open-source, privacy-first products actually win: **launch spikes, search, word-of-mouth loops, and ecosystem placement.** The good news: the product's strongest properties (verifiable privacy, no-bot capture, free) are exactly the properties those channels reward.

The asset inventory is already unusually good: a polished README with a 30-second demo video, five SEO guide pages and four dated competitor comparisons on lokalbot.com, a signed/notarized DMG, an MCP server, and a `LokalBot for LLMs` block for AI-search answers. What's missing is **distribution**: nobody has pointed the firehoses at these assets yet.

Everything below is ranked by (audience reached × conversion likelihood) ÷ effort, and nothing requires adding a network surface to the app.

---

## 1. Launch moments — the spikes that seed everything else

**Effort: S per launch. One-time each, but they permanently seed search, stars, and word of mouth.**

A free local-AI Mac app is close to ideal Show HN / r/LocalLLaMA material, and there's no evidence any launch has happened. Do these as discrete, spaced events (2–3 weeks apart), each pegged to a release with something demonstrable:

1. **Show HN.** Title formula that fits HN culture: concrete capability + verifiable privacy claim, e.g. *"Show HN: LokalBot – records both sides of a Mac meeting without a bot, fully on-device (GPLv3)"*. The README's "point Little Snitch at it" challenge is the comment-thread ace: invite skeptics to verify, don't ask them to trust. First comment from the maintainer should cover the three questions HN will ask anyway: why no sandbox (Core Audio taps), why Apple Silicon only, what exactly touches the network.
2. **r/LocalLLaMA** (~1M members, exactly the target user). Lead with the model stack table from the README — that audience wants tokens/s, quantizations, and the fact that you can point it at your own GGUF/Ollama. Separate later posts for standalone capabilities: Cotyping as "system-wide local autocomplete," the Parakeet ~190× realtime benchmark.
3. **r/macapps, r/MacOS, r/privacy, r/selfhosted, r/ObsidianMD** (the Markdown/Obsidian export is the hook for the last one). One post each, native to each subreddit's norms, spaced out — not a same-day blast, which reads as spam and gets cross-reported.
4. **Product Hunt** last, once the GitHub social proof exists from 1–3. PH loves polished video; the hero-demo assets in `Video/` are already built for this.

**Rule for all of them:** the maintainer posts as themselves, answers every comment for the first 24 h, and never astroturfs. For a privacy product, being caught doing fake-grassroots marketing is fatal; being visibly one honest developer is itself the marketing.

**Done when:** each channel has had its post; HN + r/LocalLLaMA drive the first meaningful star/download spike.

## 2. Homebrew cask — meet developers where they install

**Effort: S. Permanent, compounding.**

There is no cask today. `brew install --cask lokalbot` is how a large fraction of the exact target user (developer with an Apple Silicon Mac) installs apps, and a cask listing is itself discovery (`brew search meeting`, casks are indexed by every "best Mac apps" scraper).

1. Submit a cask to `homebrew/cask` (requirements already met: stable versioned DMG on GitHub Releases, signed + notarized). Sparkle's appcast can feed `livecheck` so version bumps are automated.
2. Add the install command to README + website download sections.
3. Same motion for **AlternativeTo** (create the listing, seed it as an alternative to Granola, Otter, Rewind/Limitless, Superwhisper, Krisp — the comparison pages already make the case), **Privacy Guides forum**, and the awesome-lists: `awesome-mac`, `awesome-macos`, `awesome-privacy`, `open-source-mac-os-apps`. Each is a one-time PR/listing that ranks forever.

**Done when:** `brew install --cask lokalbot` works and AlternativeTo shows LokalBot on the Granola/Otter/Rewind alternatives pages.

## 3. Widen the SEO engine that already exists

**Effort: M, ongoing but batchable.**

The comparison pages (`web/lokalbot-vs-*.html`) target the right high-intent queries. Extend the same machinery:

1. **More comparisons** — the missing high-volume ones: vs Otter.ai, vs Fireflies, vs Fathom, vs Limitless (distinct query from Rewind now), vs MacWhisper, vs Krisp. Same dated-and-sourced format that already exists; it's a template job.
2. **"Alternative" pages** — "Granola alternative," "Otter alternative (no bot, free)" are distinct queries from "X vs Y" and convert better. One page per major competitor.
3. **Benchmarks as content** — `Benchmarks/` exists in the repo. Publish a living "local transcription speed on Apple Silicon (M1→M4)" page. Nobody else publishes reproducible numbers; it earns backlinks from the local-AI community and ranks for model-name queries (Parakeet, Granite Speech, Qwen3-ASR) with near-zero competition.
4. **AI-search optimization** — the `LokalBot for LLMs` README block is ahead of the curve. Mirror it as `web/llms.txt`, and keep competitor-page claims dated/sourced, since LLM answer engines increasingly cite exactly such pages for "private Granola alternative" questions.
5. Keep the discipline from `web/CLAUDE.md`: extensionless canonicals, sitemap entries per page.

**Done when:** every major competitor query has both a "vs" and an "alternative" page, and the benchmarks page is live and linked from README.

## 4. Ecosystem placement — the MCP/agent surface is a growth channel

**Effort: S. Rides someone else's growth curve.**

`lokalbot-cli mcp` + the one-click `.mcpb` bundle is a real differentiator ("give Claude/Cursor memory of your meetings — locally") aimed at the fastest-growing developer audience there is.

1. Submit the MCP server to the registries agents actually browse: the official MCP registry, Anthropic's directory when open for desktop-extension listings, Cursor's directory, plus the `awesome-mcp-servers` lists.
2. A dedicated `web/mcp.html` page: "Give your coding agent a memory of your meetings" with the three-line setup for Claude Code / Claude Desktop / Cursor.
3. A short screen-capture demo (agent answering "what did we decide about the auth refactor?" from the local library) — this clip is independently shareable on r/LocalLLaMA and X.

**Done when:** LokalBot appears in at least the official MCP registry and one awesome-list, with a landing page to link to.

## 5. Build the shareable-moment loop (the only "viral" mechanics that fit)

**Effort: S–M. The only in-product growth surface that doesn't violate the invariant.**

No telemetry and no cloud means no referral links, no "invite your team." What a local-first app *can* do is make its outputs travel:

1. **Opt-in export attribution.** A single settings toggle (default **off** — brand demands it): appends `Summarized locally by LokalBot — lokalbot.com` to exported/copied summaries. People paste recaps into Slack/email/Notion after every meeting; each paste is an impression in front of exactly the right audience (other meeting attendees). Off-by-default with a one-time "help others find LokalBot?" nudge post-export keeps it consensual.
2. **The verification challenge as a repeatable asset.** "Watch Little Snitch stay silent while it transcribes" is a 20-second clip nobody else in the category can film. Make it once, pin it on the website/README, repost it with every release. Invite others to reproduce it — reproduction posts are third-party endorsements.
3. **Obsidian/Logseq community.** The scheduled Markdown export makes LokalBot a "meeting notes into your vault, locally" tool. A forum post + share-your-setup thread in those communities reaches high-word-of-mouth users cheaply.

**Done when:** the attribution toggle ships (off by default) and the Little Snitch clip exists as a standalone shareable asset.

## 6. Release-cadence marketing — turn shipping into content

**Effort: S per release, ongoing.**

Releases already happen (0.5.0, 0.5.1 in the log). Attach a lightweight ritual to each:

1. **Release notes as posts.** Each notable release gets a short write-up (what shipped, one GIF) cross-posted to a repo Discussions "announcements" category and, when substantial, to the relevant subreddit. Feature-sized releases justify a fresh Show HN (HN norms allow reposts of substantially updated projects).
2. **One demo GIF per feature.** The `Docs/demo-film-kit.md` + `Video/hero-demo` tooling already exists; a 10-second GIF per headline feature is the unit of social content. GIFs of Cotyping ghost-text and Dictation are inherently demo-able.
3. **Engineering blog posts** for the deep material: "How we record both sides of a call without a bot (Core Audio process taps)," "Running four local models on one Mac without swapping" (the `InferenceBroker` story), "Why App Sandbox is off." Each is HN-frontpage-shaped and earns technical credibility that a landing page can't. Host on lokalbot.com to compound the domain.

**Done when:** the last two releases each produced at least one public post with a visual.

## 7. Measurement without telemetry

**Effort: S. Do this first, it's the scoreboard for everything above.**

The invariant forbids app telemetry; it does not forbid counting public signals:

1. **GitHub Releases download counts** (per-asset, via API) — the closest thing to installs. A tiny script snapshotting weekly into a CSV gives a trend line for free.
2. **Stars, traffic, referrers** — GitHub's built-in traffic tab (14-day window, so snapshot it), plus star history.
3. **Website analytics** — server-side/privacy-preserving only (Vercel Analytics or self-hosted Plausible on lokalbot.com). Cookieless site analytics is consistent with the brand; app telemetry is not — keep that line bright, and say so on the privacy page.
4. **Sparkle appcast fetches** — update checks hit the appcast on GitHub Releases/website; count them server-side for an active-installs proxy. Disclose it in PRIVACY.md as part of the already-disclosed update-check path (no new data, just counting requests that already occur).
5. Weekly 15-minute review: downloads, stars, top referrers → double down on whichever channel above actually moved.

**Done when:** a weekly snapshot exists and each launch/post can be matched to its download spike.

---

## Explicit non-goals

- **No paid ads, no influencer payments.** Wrong economics for a free product; the budget is maintainer hours.
- **No telemetry, ever, framed as growth necessity.** The absence of telemetry *is* the growth story.
- **No growth mechanics that spam meeting participants** (auto-emailing recaps to attendees, bot-style "this call was recorded by LokalBot" notices used as ads). The no-bot positioning dies the day the product starts advertising itself to non-users without the user's explicit intent.
- **No Windows/Linux/Intel port for reach** — out of scope per architecture; the comparison pages should keep saying so plainly, since honesty about scope converts better in this audience than pretending.

## 90-day sequencing

**Weeks 1–2 — instrument and stock the shelves (all S-effort, no code):**
Measurement scripts (§7) · Homebrew cask PR · AlternativeTo + awesome-list submissions (§2) · Little Snitch verification clip (§5.2).

**Weeks 3–6 — launch season (§1):**
Show HN → r/LocalLLaMA → r/macapps + r/privacy + r/ObsidianMD, spaced, each pegged to whatever release is current. Maintainer availability for comment duty is the gating resource — schedule launches for weeks it exists.

**Weeks 7–10 — the search engine (§3, §4):**
Otter/Fireflies/Limitless comparison + alternative pages · benchmarks page · `llms.txt` · MCP registry submissions + `web/mcp.html` + agent demo clip.

**Weeks 11–13 — loops and cadence (§5, §6):**
Opt-in export attribution toggle (the one code change in this plan) · Product Hunt launch on the next feature release · first engineering blog post · release-ritual in place.

Then steady state: §6's per-release ritual + §7's weekly review, with §3 pages added opportunistically.

## Dependencies on the product roadmap

Growth amplifies whatever the first-run experience is. Two roadmap items disproportionately affect launch-spike conversion and should ideally land before the biggest launches: **Auto model + onboarding prefetch** (roadmap item 5 — a Show HN visitor who waits ten minutes for a first recap doesn't come back) and **consent-default `.ask`** (roadmap item 2 — the top HN comment will otherwise be about silent auto-recording). Neither blocks weeks 1–2.
