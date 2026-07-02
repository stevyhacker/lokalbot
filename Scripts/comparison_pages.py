"""Per-competitor content for the web/lokalbot-vs-*.html comparison pages.

Rendered by Scripts/render_web.py into web/, where the HTML stays checked in.
To change a page: edit this file (or Scripts/compare.template.html for the
shared markup), run `python3 Scripts/render_web.py`, and commit the
regenerated HTML.

All values are raw HTML fragments inserted into the template without
escaping. "table_rows" entries are (feature, LokalBot cell, competitor cell)
tuples. Each page's "h1" doubles as its link text in the other pages'
"More comparisons" nav, and the PAGES order sets the order of those links.
"""

PAGES = [
    {
        "slug": 'lokalbot-vs-granola',
        "title": 'LokalBot vs Granola: the on-device, open-source alternative',
        "description": 'Granola is a polished cloud AI notepad. LokalBot keeps the bot-free meeting workflow but runs transcription and summaries on your Mac — no account, no upload, free and GPLv3.',
        "og_title": 'LokalBot vs Granola — the on-device alternative',
        "og_description": 'Same bot-free meeting notes, zero cloud: transcription and summaries run on your Mac. Free, open source, no account.',
        "h1": 'LokalBot vs Granola',
        "lead": 'Granola is one of the most polished AI notepads around — bot-free capture, great templates, strong team features. The trade-off is that your meetings are processed in the cloud, under an account. LokalBot keeps the bot-free workflow but runs the AI on your Mac: no account, no upload, nothing to opt out of.',
        "competitor_column": 'Granola',
        "table_rows": [
            (
                'Where the AI runs',
                'On your Mac — Neural Engine transcription, local llama.cpp summaries',
                'In the cloud, via third-party AI providers',
            ),
            (
                'Account required',
                '<i class="ph ph-x" aria-hidden="true"></i>None',
                '<i class="ph ph-check" aria-hidden="true"></i>Yes',
            ),
            (
                'Works offline',
                '<i class="ph ph-check" aria-hidden="true"></i>Fully, after a one-time model download',
                'Needs a connection for AI notes',
            ),
            (
                'Bot-free meeting capture',
                '<i class="ph ph-check" aria-hidden="true"></i>Mic + system-audio tap, labeled Me / Them',
                '<i class="ph ph-check" aria-hidden="true"></i>Yes — no bot joins your call',
            ),
            (
                'Model training on your data',
                'Nothing leaves the Mac, so there is nothing to opt out of',
                '<span class="dim">&ldquo;Opt out of model training any time&rdquo; is a listed plan feature</span>',
            ),
            (
                'System-wide dictation',
                '<i class="ph ph-check" aria-hidden="true"></i>Hold ⌥ Space in any app',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Day timeline',
                '<i class="ph ph-check" aria-hidden="true"></i>Opt-in screenshots + OCR, deleted after 14 days by default',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Writing autocomplete',
                '<i class="ph ph-check" aria-hidden="true"></i>Cotyping, in almost any app',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Source code',
                'Open source, GPLv3',
                'Proprietary',
            ),
            (
                'Price',
                'Free',
                'Free tier · Business $14 per user/mo · Enterprise $35 per user/mo',
            ),
            (
                'Platforms',
                'macOS 15+ on Apple Silicon',
                'macOS, Windows, iOS',
            ),
        ],
        "competitor_pick_title": 'Pick Granola if&hellip;',
        "competitor_pick_sub": 'It is a genuinely good product — these are real advantages.',
        "competitor_pick_items": [
            'You want shared folders, team workspaces, and admin controls',
            'You capture meetings on iOS or Windows too',
            'You prefer AI-polished typed notes over full transcripts',
            'Cloud processing by a well-funded vendor is acceptable to you',
        ],
        "lokal_pick_sub": 'Built for when the content of your meetings must stay yours.',
        "lokal_pick_items": [
            "Your meetings can't leave the machine — legal, health, finance, source protection",
            "You want no account and no per-seat subscription — it's free",
            'You want dictation, a day timeline, and autocomplete in the same app',
            'You want source code you — or your security team — can read',
        ],
        "faq": [
            (
                "Isn't bot-free capture the differentiator?",
                'Not anymore — Granola and several others skip the meeting bot now. The differentiator is where processing happens. LokalBot transcribes and summarizes on the Mac itself; your audio and notes are never uploaded anywhere.',
            ),
            (
                'What does LokalBot send over the network?',
                'A one-time model download and update checks. Meeting audio, transcripts, summaries, and screenshots never leave the machine — there is no backend to send them to.',
            ),
            (
                'Can I try LokalBot next to Granola?',
                'Yes. LokalBot is free — run it on your next few meetings and compare the notes. Neither app puts a bot in your call, so nobody on the call will notice either one.',
            ),
        ],
        "cta_title": 'Keep your meetings on your Mac.',
        "disclaimer": 'Granola is a trademark of its owner; LokalBot is not affiliated with or endorsed by it. Details are based on public pages and pricing as of July 2026 and may change — if something here is wrong or out of date, <a href="https://github.com/stevyhacker/lokalbot/issues" target="_blank" rel="noopener">open an issue</a> and we\'ll fix it.',
    },
    {
        "slug": 'lokalbot-vs-rewind',
        "title": "LokalBot vs Rewind: a local timeline that's still alive",
        "description": "Rewind's Mac app is discontinued — the team became Limitless, acquired by Meta. LokalBot's day timeline keeps the idea on your Mac: screenshots, OCR, and meetings, open source.",
        "og_title": "LokalBot vs Rewind — a local timeline that's still alive",
        "og_description": "Rewind is gone. LokalBot's day timeline carries the idea forward: screenshots, OCR, and meetings — on your Mac, open source.",
        "h1": 'LokalBot vs Rewind',
        "lead": "Rewind pioneered &ldquo;search everything you've seen on your Mac.&rdquo; Its app is now discontinued: the team pivoted to the Limitless wearable, Meta acquired Limitless in December 2025, and rewind.ai today hosts an unrelated site. LokalBot's day timeline carries the idea forward — smaller, open source, and still entirely on your Mac.",
        "competitor_column": 'Rewind (as it was)',
        "table_rows": [
            (
                'Status',
                '<i class="ph ph-check" aria-hidden="true"></i>Actively developed',
                'Discontinued — the team moved to Limitless, now part of Meta',
            ),
            (
                'Screen memory',
                'Periodic screenshots + OCR, opt-in, searchable by every word',
                'Continuous compressed screen recording, always on',
            ),
            (
                'Meeting notes',
                '<i class="ph ph-check" aria-hidden="true"></i>Bot-free capture with Me / Them tracks, summarized locally',
                'Local capture; &ldquo;Ask Rewind&rdquo; answers were generated with cloud AI',
            ),
            (
                'Retention',
                'Deleted after 14 days by default; keeping longer is an explicit opt-in',
                'Grew until you trimmed it yourself',
            ),
            (
                'Encryption at rest',
                '<i class="ph ph-check" aria-hidden="true"></i>Screenshots are AES-GCM encrypted on disk',
                'Stored locally on disk',
            ),
            (
                'System-wide dictation',
                '<i class="ph ph-check" aria-hidden="true"></i>Hold ⌥ Space in any app',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Writing autocomplete',
                '<i class="ph ph-check" aria-hidden="true"></i>Cotyping, in almost any app',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Source code',
                'Open source, GPLv3',
                'Proprietary',
            ),
            (
                'Price',
                'Free',
                'Was subscription-based; no longer purchasable',
            ),
            (
                'Platforms',
                'macOS 15+ on Apple Silicon',
                'macOS (app no longer available)',
            ),
        ],
        "competitor_pick_title": 'Pick Limitless (Meta) if&hellip;',
        "competitor_pick_sub": "That's where Rewind's team and ambition went.",
        "competitor_pick_items": [
            'You want a wearable that captures conversations away from the desk',
            "You're comfortable with cloud-hosted memory — now under Meta",
            'A subscription for hosted AI features is fine by you',
        ],
        "lokal_pick_sub": "You want the Rewind workflow on today's Mac — with source you can read.",
        "lokal_pick_items": [
            'A colour-coded day timeline with time-by-app totals',
            "Search every word you've seen — opt-in screenshots + OCR",
            'Ask your day questions and get answers from a local model, not a cloud API',
            'It cleans up after itself: 14-day retention by default, encrypted at rest',
        ],
        "faq": [
            (
                'Is LokalBot a drop-in Rewind replacement?',
                "Not entirely, and it doesn't try to be. Rewind recorded your screen continuously and let you scrub it like a video. LokalBot takes periodic screenshots with OCR plus app and window tracking — lighter on disk, easier to reason about, and combined with full meeting capture. You get the search and the timeline, not the video scrubber.",
            ),
            (
                'What actually happened to Rewind?',
                'The company behind it shifted to Limitless, a wearable pendant with cloud-hosted memory, and stopped developing the Mac app. Meta acquired Limitless in December 2025. The rewind.ai domain now hosts an unrelated service — the original app is simply gone.',
            ),
            (
                'How is this different from Windows Recall?',
                "Recall is Windows-only and drew heavy privacy scrutiny. LokalBot's timeline is for the Mac, off until you turn it on, encrypted at rest, auto-deleting after 14 days by default — and the code that does all of that is open for you to audit.",
            ),
        ],
        "cta_title": 'Your timeline, back on your Mac.',
        "disclaimer": 'Rewind and Limitless are trademarks of their owners; LokalBot is not affiliated with or endorsed by them. Details are based on public reporting as of July 2026 — if something here is wrong or out of date, <a href="https://github.com/stevyhacker/lokalbot/issues" target="_blank" rel="noopener">open an issue</a> and we\'ll fix it.',
    },
    {
        "slug": 'lokalbot-vs-superwhisper',
        "title": 'LokalBot vs Superwhisper: on-device dictation compared',
        "description": 'Superwhisper is a deep, dedicated dictation app. LokalBot includes hold-⌥-Space dictation as one feature of a free, open-source on-device workspace with meetings, a day timeline, and autocomplete.',
        "og_title": 'LokalBot vs Superwhisper — on-device dictation compared',
        "og_description": 'One is a dedicated dictation tool. The other is a free, open-source workspace where dictation is one of five features. An honest comparison.',
        "h1": 'LokalBot vs Superwhisper',
        "lead": "The honest version: if dictation is the only thing you want, Superwhisper is the deeper tool — custom modes, AI rewrites, an iOS keyboard. LokalBot's dictation is simpler by design — hold ⌥ Space, speak, it types — and it comes inside a free, open-source workspace that also records your meetings, tracks your day, and autocompletes your writing.",
        "competitor_column": 'Superwhisper',
        "table_rows": [
            (
                'Dictation',
                '<i class="ph ph-check" aria-hidden="true"></i>Hold or toggle ⌥ Space, live transcript pill, pastes at the cursor',
                '<i class="ph ph-check" aria-hidden="true"></i>Deeper: custom modes, AI text processing, per-app behavior',
            ),
            (
                'Runs on-device',
                '<i class="ph ph-check" aria-hidden="true"></i>Always — there is no cloud path for your audio',
                '<i class="ph ph-check" aria-hidden="true"></i>Local models, with optional cloud models',
            ),
            (
                'Audio retention',
                'Scratch recording is deleted right after transcription',
                '<span class="dim">Configurable in-app</span>',
            ),
            (
                'Meeting notetaker',
                '<i class="ph ph-check" aria-hidden="true"></i>Bot-free capture with Me / Them tracks, summarized locally',
                '<i class="ph ph-x" aria-hidden="true"></i>Voice-first tool, not a system-audio meeting notetaker',
            ),
            (
                'Day timeline',
                '<i class="ph ph-check" aria-hidden="true"></i>Opt-in screenshots + OCR with app tracking',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Writing autocomplete',
                '<i class="ph ph-check" aria-hidden="true"></i>Cotyping ghost text as you type',
                '<i class="ph ph-x" aria-hidden="true"></i>No — AI modes transform what you dictate instead',
            ),
            (
                'Source code',
                'Open source, GPLv3',
                'Proprietary',
            ),
            (
                'Price',
                'Free — dictation included, nothing gated',
                'Free tier · Pro subscription or a lifetime license (~$250 at last check)',
            ),
            (
                'Platforms',
                'macOS 15+ on Apple Silicon',
                'macOS and iOS',
            ),
        ],
        "competitor_pick_title": 'Pick Superwhisper if&hellip;',
        "competitor_pick_sub": 'Dictation power users are its whole audience, and it shows.',
        "competitor_pick_items": [
            'Dictation is your primary way of writing, all day',
            'You want per-app modes and AI rewriting of what you say',
            'You dictate on your iPhone too',
        ],
        "lokal_pick_sub": 'Good dictation, plus everything around it — for free.',
        "lokal_pick_items": [
            'You want dictation and meeting notes, a day timeline, and autocomplete',
            'One model download covers your meetings and your dictation',
            'You prefer free and open source over a license',
            'You want a strict no-cloud guarantee you can verify in the code',
        ],
        "faq": [
            (
                'Which speech models does LokalBot use?',
                'Granite, Parakeet, or Whisper-family models running on the Neural Engine. Dictation reuses whichever engine and language you picked for meetings, and keeps it warm so transcription starts instantly when you hold the key.',
            ),
            (
                'Does LokalBot keep my dictation audio?',
                'No. It records to a scratch file, transcribes it on-device, pastes the text, and deletes the recording. It even pauses your music before it starts listening.',
            ),
            (
                'Can I run both apps?',
                'Sure — they use different shortcuts. Some people will want Superwhisper for heavy dictation workflows and LokalBot for meetings and everything else. LokalBot is free, so trying the combination costs nothing.',
            ),
        ],
        "cta_title": 'Speak anywhere. Stays on your Mac.',
        "disclaimer": 'Superwhisper is a trademark of its owner; LokalBot is not affiliated with or endorsed by it. Details are based on public pages and pricing as of July 2026 and may change — if something here is wrong or out of date, <a href="https://github.com/stevyhacker/lokalbot/issues" target="_blank" rel="noopener">open an issue</a> and we\'ll fix it.',
    },
    {
        "slug": 'lokalbot-vs-hyprnote',
        "title": 'LokalBot vs Hyprnote (anarlog): two open-source local notetakers',
        "description": 'Hyprnote — now anarlog — is a kindred open-source, local-first meeting notetaker. How LokalBot differs: built-in local AI with no API keys, GPLv3, plus dictation, a day timeline, and autocomplete.',
        "og_title": 'LokalBot vs Hyprnote — two open-source local notetakers',
        "og_description": 'Both are open-source and local-first. They differ on scope, built-in local AI vs bring-your-own keys, and license.',
        "h1": 'LokalBot vs Hyprnote',
        "lead": "Hyprnote is the closest cousin on this list: open-source, local-first meeting notes — it helped prove the category. In 2026 the app was renamed anarlog, and the team's newest product is Char, a separate cloud-era notepad in private beta (hyprnote.com now lands on char.com). The open-source notetaker remains maintained, and it's good. Here's how LokalBot differs.",
        "competitor_column": 'Hyprnote (anarlog)',
        "table_rows": [
            (
                'Scope',
                'Workspace: meetings + dictation + day timeline + autocomplete + chat + CLI',
                'Meeting notetaker with markdown notes',
            ),
            (
                'Local transcription',
                '<i class="ph ph-check" aria-hidden="true"></i>Neural Engine — Granite, Parakeet, or Whisper-family',
                '<i class="ph ph-check" aria-hidden="true"></i>On-device',
            ),
            (
                'Summaries / LLM',
                '<i class="ph ph-check" aria-hidden="true"></i>Local llama.cpp built in — works with no keys and no setup',
                'Bring your own: OpenAI, Anthropic, Gemini, OpenRouter — or local via Ollama / LM Studio',
            ),
            (
                'Cloud path',
                'None by default — no account, no API keys',
                'Optional cloud LLMs through your own API keys',
            ),
            (
                'Notes on disk',
                'SQLite library with full-text and vector search',
                '<span class="dim">Markdown files — easy to sync or put in git</span>',
            ),
            (
                'System-wide dictation',
                '<i class="ph ph-check" aria-hidden="true"></i>Hold ⌥ Space in any app',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Day timeline',
                '<i class="ph ph-check" aria-hidden="true"></i>Opt-in screenshots + OCR with app tracking',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'Writing autocomplete',
                '<i class="ph ph-check" aria-hidden="true"></i>Cotyping ghost text',
                '<i class="ph ph-x" aria-hidden="true"></i>No',
            ),
            (
                'License',
                "GPLv3 — every fork's improvements stay open",
                'MIT — permissive; forks may go closed',
            ),
            (
                'Direction',
                'Independent, on-device only',
                "Maintained; the company's focus now includes Char, a cloud notepad in private beta",
            ),
            (
                'Platforms',
                'macOS 15+ on Apple Silicon',
                'Releases per platform on GitHub',
            ),
        ],
        "competitor_pick_title": 'Pick Hyprnote (anarlog) if&hellip;',
        "competitor_pick_sub": 'A kindred project with different choices — all defensible.',
        "competitor_pick_items": [
            'Markdown files on disk are your organizing principle — sync via git, iCloud, anything',
            'You already run Ollama or have LLM API keys you like',
            "You prefer the MIT license, or you're not on an Apple Silicon Mac",
        ],
        "lokal_pick_sub": 'Local AI with the batteries included, and a wider brief.',
        "lokal_pick_items": [
            'You want zero setup: recommended models in-app, no keys, no separate LLM runner',
            'You want meetings plus dictation, a day timeline, and autocomplete',
            "Copyleft matters: GPLv3 keeps every fork's improvements open",
            'You want everything searchable in one place — transcripts, notes, and your screen',
        ],
        "faq": [
            (
                "Aren't you basically the same project?",
                "We overlap on the part that matters — local, bot-free meeting notes — and that's a good thing; the category needs more of it. We differ on scope (a workspace vs a notetaker), on shipped local AI vs bring-your-own model, and on license.",
            ),
            (
                "What's Char?",
                "The new product from Hyprnote's team, backed by Y Combinator: an AI notepad in private beta at char.com. It's separate from the open-source anarlog app, which the team says remains maintained.",
            ),
            (
                'Why GPLv3 instead of MIT?',
                'Copyleft. Anyone can fork LokalBot, but improvements have to stay open. For an app that hears your meetings and reads your screen, we want the audit path to survive every fork — the code you can read should always be the code you run.',
            ),
        ],
        "cta_title": 'Local AI, batteries included.',
        "disclaimer": 'Hyprnote, anarlog, and Char are trademarks of their owners; LokalBot is not affiliated with or endorsed by them. Details are based on their public repository and sites as of July 2026 — if something here is wrong or out of date, <a href="https://github.com/stevyhacker/lokalbot/issues" target="_blank" rel="noopener">open an issue</a> and we\'ll fix it.',
    },
]
