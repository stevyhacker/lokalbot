---
format: 1920x1080
message: "LokalBot remembers your workday and answers with proof, on-device by default"
arc: Demo Loop (challenge-hook variant) — quiz → instant answer → demo cycles → trust proof → CTA
audience: developers and privacy-minded Mac users (HN, r/LocalLLaMA, X)
mode: autonomous
music: driving confident minimal-electronic tech underscore
---

## Video direction

- palette: dark register only, all six frames — ink `#0B1220` ground, cream `#EFF6FA` type, teal `#23C4AE` as the lone accent (kickers, rule stubs, inked clauses, drawn strokes, glows). One sanctioned exception: the small amber REC dot inside the recreated meeting window in Frame 3 — the app's own live-capture color, confined to that UI surface. Never a third hue anywhere else; never cream on teal.
- type: the broadside ramp from `frame.md` by role — every display or statement line in lowercase weight-900 SF Pro Display, negative-tracked, exactly one display moment per frame; all chrome (kickers, window titles, table headers, badges, chips) uppercase mono at 0.14em. On-screen copy follows the founder rules: no em-dashes (use `·` as the separator), no arrow glyphs, lowercase display, no invented figures.
- motion grammar + reveal model: long-tail `power3` settles everywhere; smooth beats bouncy. Overshoot is budgeted to exactly two moments — Frame 4's inner-edge badges and Frame 6's wordmark letter cascade — nothing else pops. Every frame reveals to the voiceover: at t=0 only what the VO is saying is on screen; each further element lands on its spoken cue, most of them in the back half. During any hold: stillness, at most low-amplitude subtle jitter. No lazy breathing, no back-half camera drift.
- rhythm / held frames: six beats in 30 seconds runs quick, so the deliberate stills carry the rhythm — Frame 5's final scoped network result is the held trust climax, Frame 3's last second reads still on the empty participant slot, and Frame 6 resolves to a dead-static end card by ~3.2s.
- UI recreations: Frames 2, 3, and 5 build idealized macOS-style windows — hairline `#1B2A40` borders, lifted window ground `#101B2D`, muted text `#9FB2C4`, small corner radius allowed on windows only. They are staged product surfaces, never decoration; content inside them is set in the reading ramp, never display type. The staged demo thread is one continuous story across frames: the 9:15 standup where the beta cut moved to Friday.
- negative list: no front-load-then-freeze (slideshow) and no independently floating elements (screensaver); no bounce or elastic entrances outside the two budgeted pops; no purple-blue AI gradients, bokeh, or decorative shapes standing in for product UI; no drop shadows or gradient grounds outside the window recreations; no uppercase display type; no em-dashes or arrow glyphs in on-screen copy; nothing load-bearing in the bottom ~17% caption band.

## Frame 1 — Pop quiz

- scene: Giant lowercase display type asks the quiz question while a teal countdown ring drains 3, 2, 1 to a buzz
- voiceover: "Pop quiz. What did you agree to at nine fifteen this morning?"
- duration: 3.904s
- transition_in: cut
- status: animated
- src: compositions/frames/01-pop-quiz.html
- type: hook
- persuasion: Pain validation
- beat: curiosity + tension
- blueprint: kinetic-type-beats (Adapt)
- focal: the question line (built type — no captured assets per asset-descriptions.md)
- roles: (no captured candidates; every surface is worker-built HTML)
- sfx: click-soft, error
- asset_candidates: (none — pure typography plus a drawn countdown ring; original HTML per asset-descriptions.md)

narrativeRole: Direct-address challenge that makes the viewer feel their own memory failing before the product ever appears.
keyMessage: You cannot answer this about your own workday.

Adapt: keep sub-shape B's beats-replace-in-place engine and the settle-and-hold finale; the added countdown ring is the quiz-show prop that arms the transition buzz — the type still carries the shot.
Scene 1 (0.0–1.2s): bare ink field, chrome suppressed. "pop quiz." lands dead-center as two kinetic beat-slams timed to the spoken words ("pop" @0.05, "quiz." @0.5), display lowercase 900 in cream — Centered, type IS the composition, ~60% of frame width. Camera locked.
Scene 2 (1.2–2.6s): hard cut clears the slam; the question builds by per-word staggered reveal exactly on the word rail — "what did you agree to at 9:15 this morning?" stepped down to h1 across two lines, upper-center; "9:15" lands inked teal @2.2 with a quick drawn underline. Nothing else on screen.
Scene 3 (2.6–3.9s): the question holds while a thin teal countdown ring self-draws on the right third and drains as its center numeral hard-cuts 3, 2, 1 on ~0.4s ticks; at ~3.6s the ring flashes and the numeral cuts to blank as the buzzer lands — the question stays up, still, through the cut. Asymmetric 70/30, question dominant.

## Frame 2 — LokalBot answers

- scene: A Quick Recall style overlay recreation; the question is typed, an answer card lands instantly with the exact quote and a Me/Them source citation row
- voiceover: "You forgot. Your Mac didn't. LokalBot answers from a private memory of your whole workday, quoting the source."
- duration: 7.104s
- transition_in: zoom-through
- status: animated
- src: compositions/frames/02-recall-answer.html
- type: product_intro
- persuasion: Show-don't-tell proof
- beat: relief + awe
- blueprint: cursor-ui-demo (Adapt)
- focal: the Quick Recall overlay recreation (built HTML — no captured assets per asset-descriptions.md)
- roles: (no captured candidates; every surface is worker-built HTML)
- sfx: whoosh-short, chime
- asset_candidates: (none — stylized Quick Recall overlay built in HTML per asset-descriptions.md)

narrativeRole: Resolves the hook's tension and lands the message by beat 2: the product answers instantly and shows its evidence.
keyMessage: LokalBot remembers your workday and proves its answers.

Adapt: keep the signature — a reconstructed product surface changing state live, beat by beat, with the camera settling static on the payoff; the actor is the keyboard rather than a mouse cursor (Quick Recall is keyboard-first), so the typed caret and hotkey chrome do the cursor's job.
Scene 1 (0.0–2.5s): still the bare ink field — the jab lands as type before any UI: "you forgot." hard-cuts in centered at h2 @0.1; @1.1 it token-swaps in place to "your mac didn't." with "didn't" inked teal. Centered single line, ~50% width. No product yet.
Scene 2 (2.5–4.7s): on "LokalBot answers" @2.5 the line scale-swaps away and the Quick Recall overlay arrives centered on a smooth long-tail settle (no overshoot): a floating spotlight bar on the lifted window ground, mono kicker "⌃ ⌥ SPACE · QUICK RECALL" above it, and the question "what did I agree to at 9:15?" types on behind a blinking teal caret at reading size. @3.6, as "answers" is spoken, an answer card slides up beneath the bar: "the beta cut moved to friday." in lead type. Centered stack, overlay ~55% width, 3 depth layers (field, overlay, card). A slow push-in starts toward the card.
Scene 3 (4.7–7.1s): the push settles by 5.5 and stops; @6.0 on "quoting the source" a citation row reveals at the card's foot — mono chip "STANDUP · 9:15 · THEM" plus the quoted transcript line "friday works, let's move the beta cut." — and a keyword glow sweeps the quote left to right as the words are spoken. Then everything reads still to the cut; the caret blink is the only life.

## Frame 3 — No bot in your call

- scene: A meeting recap window recreation as hero; Me/Them speaker turns cycle beneath a decisions list, an amber capture dot pulses, an empty participant slot makes the point that nothing joined
- voiceover: "It captures both sides of your call. Nothing joins the meeting."
- duration: 3.968s
- transition_in: push-slide LEFT
- status: animated
- src: compositions/frames/03-no-bot.html
- type: feature_showcase
- persuasion: Negative contrast
- beat: trust + control
- blueprint: device-surface-showcase (Adapt)
- focal: the meeting recap window recreation (built HTML — no captured assets per asset-descriptions.md)
- roles: (no captured candidates; every surface is worker-built HTML)
- sfx: whoosh-short, click-soft
- asset_candidates: (none — stylized meeting recap window built in HTML per asset-descriptions.md)

narrativeRole: First demo cycle; differentiates from every bot-in-the-meeting notetaker without naming the category.
keyMessage: Both sides captured, no bot in the room.

Adapt: keep the static-tour variant's signature — the surface held as hero while its content cycles at element level (camera static, no cursor); the cycling screens become speaker turns inside one recap window, and the payoff is the participant strip rather than a final app screen.
Scene 1 (0.0–1.3s): the recap window slides in from the right edge and settles center-right — asymmetric 60/40, window as hero at ~55% width — lifted window ground, hairline border: mono title bar "STANDUP · 9:15" with a small amber REC dot that pulses once, and a participant strip with two tiles ("ME", "THEM") plus one empty dashed slot. On "both sides" @0.9 the first speaker turn reveals inside: "Me · we need a call on the beta date." with a short waveform stub.
Scene 2 (1.3–2.6s): the turns cycle — the Me turn slides up and dims as "Them · friday works, let's move the beta cut." pushes in beneath @1.6, each with its own side waveform; a mono "ON-DEVICE TRANSCRIPT" tag holds at the window foot. The left third of the frame stays quiet ink.
Scene 3 (2.6–4.29s): on "Nothing joins" @2.7 the left third answers: "nothing joins." lands at h2 lowercase by per-word staggered reveal, "nothing" inked teal; @3.1 a mono caption "NO BOT" stamps beneath the empty dashed participant slot as a teal hairline draws around it. Window and line then hold dead still to the cut.

## Frame 4 — It writes with you

- scene: Two paired panels side by side; left, a dictation pill turns speech into an inserted sentence; right, dimmed ghost text completes a typed line and a Tab keycap accepts it
- voiceover: "Dictate into any app, and Tab accepts autocomplete from a model on your machine."
- duration: 5.312s
- transition_in: push-slide LEFT
- status: animated
- src: compositions/frames/04-writes-with-you.html
- type: feature_showcase
- persuasion: Feature-to-benefit translation
- beat: power + ease
- blueprint: comparison-split (Reproduce)
- focal: the paired dictation and cotyping cards (built HTML — no captured assets per asset-descriptions.md)
- roles: (no captured candidates; every surface is worker-built HTML)
- sfx: whoosh-short, key-press
- asset_candidates: (none — stylized editor and dictation panels built in HTML per asset-descriptions.md)

narrativeRole: Second demo cycle; widens the product from recall to writing, proving it works the whole day in every app.
keyMessage: It also writes with you, everywhere, on-device.

Reproduce: the slots map cleanly — two complementary writing capabilities of equal weight; the split-tilt entry and inner-edge badges keep their shape with the timing shifted onto the word rail.
Scene 1 (0.0–0.8s): on the ink field a title slides down into the upper third: "it writes with you" at h3 lowercase, "writes" inked teal. Two faint teal ambient glows bloom low behind the still-empty card positions near 30% and 70%.
Scene 2 (0.4–1.9s): as "Dictate" is spoken the left card arrives from the left wing with the mirrored book-open tilt, scaling to seat — split-screen symmetry, equal card widths ~38% each: inside, a dictation pill (mono "⌥ SPACE · HOLD" chrome, small waveform bars stepping deterministically) and beneath it the spoken sentence typing into a field: "send the recap to the team."
Scene 3 (1.9–3.7s): on "Tab accepts" @2.1 the right card mirrors in from the right wing: an editor line with the typed stem "the beta moves to" and its ghost completion " friday, july 24." dimmed to ~45%; @3.0 a Tab keycap under the line compresses and springs back as the ghost text solidifies to full cream — the acceptance is the beat.
Scene 4 (3.7–5.31s): on "model on your machine" @4.0 the two inner-edge badges spring-pop ~0.3s apart — left "ANY APP", right "ON-DEVICE MODEL" — the shot's one budgeted overshoot; then the pair settles into phase-opposed subtle jitter and holds.

## Frame 5 — Verify the built-in path

- scene: A scoped network-check recreation shows no outbound connection during built-in processing after models are downloaded and update checks are off; the words built-in processing, no account, no telemetry land beside it
- voiceover: "Built-in processing stays local. No account. No telemetry. Check the network yourself."
- duration: 6.037s
- transition_in: blur-crossfade
- status: animated
- src: compositions/frames/05-network-silence.html
- type: social_proof
- persuasion: Falsifiable-claim proof — instead of quoting users, the frame stages the documented built-in-path test a skeptic can reproduce
- beat: skepticism → trust
- blueprint: compose
- focal: the network monitor window recreation (built HTML — no captured assets per asset-descriptions.md)
- roles: (no captured candidates; every surface is worker-built HTML)
- sfx: riser, impact-bass-1
- asset_candidates: (none — stylized network monitor window built in HTML per asset-descriptions.md)

narrativeRole: The trust beat for an HN-skeptic audience; the claim is staged as an experiment the viewer could reproduce.
keyMessage: The local processing claim is checkable, with downloads and update checks scoped honestly.

Compose: no blueprint stages a falsifiable test; built from the motion vocabulary — a beat-cut claim stack, a window reveal on its spoken cue, finite dash-flow aliveness, then the held silence as the climax.
Scene 1 (0.0–3.0s): on the ink field the three scoped claims land beat-by-beat down the left third exactly as the VO names each — "built-in processing" @0.3, "no account" @1.3, "no telemetry" @2.4 — each a broadside bullet line (teal "/" marker, lead type, hard-cut in with a short long-tail settle), stacking top to bottom. Asymmetric 40/60; the right two-thirds stays empty ink, waiting. No other motion.
Scene 2 (3.0–4.9s): on "Verify the network yourself" @3.4 the network window rises into the right two-thirds on a smooth settle: mono title "NETWORK CHECK · BUILT-IN BACKEND", column headers "PROCESS · REMOTE ADDRESS · BYTES", and an empty table; a thin teal scan line sweeps down the empty rows once while three mono micro-labels pulse briefly in the margins — "TRANSCRIBING", "SUMMARIZING", "AUTOCOMPLETE" — the app visibly working while the table stays empty. A permanent scope note reads "MODELS DOWNLOADED · UPDATES OFF".
Scene 3 (5.0–6.04s): the labels fade, the scan line completes and vanishes, and a single mono row stamps into the empty table: "0 OUTBOUND DURING PROCESSING". Dead-still held read to the cut; this is the video's trust climax without implying the app never connects for documented downloads, updates, or approved remote inference.

## Frame 6 — Get LokalBot

- scene: The LokalBot wordmark assembles, then a fast push lands on lokalbot.com with a free and open source line
- voiceover: "Your workday, remembered. Free at lokalbot dot com."
- duration: 3.648s
- transition_in: zoom-through
- status: animated
- src: compositions/frames/06-cta.html
- type: cta
- persuasion: Friction reduction
- beat: motivation + urgency-to-act
- blueprint: logo-assemble-lockup (Adapt)
- focal: the lokalbot wordmark lockup (built type — no captured assets per asset-descriptions.md)
- roles: (no captured candidates; every surface is worker-built HTML)
- sfx: whoosh-short, impact-bass-2
- asset_candidates: (none — wordmark set in type per asset-descriptions.md)

narrativeRole: Converts the earned trust into one action with zero cost objections: free, open source, one URL.
keyMessage: Download it now at lokalbot.com.

Adapt: keep the wordmark letter cascade and the left-to-right URL wipe from the CTA variants; at 3.6s the camera push-through is cut — the tagline yields by scale-swap and the lockup carries the close. This is the final frame, so the dead-static end card is the exit.
Scene 1 (0.0–1.7s): on the ink field the tagline assembles per-word on the rail — "your workday, remembered." at h2 lowercase, centered, "remembered" inked teal @0.8. Nothing else on screen.
Scene 2 (1.7–2.6s): on "Free" @1.8 the tagline scale-swaps away and the wordmark cascades in letter by letter, left to right, with the budgeted light overshoot — a teal "/" mark then "lokalbot" at display weight — locking dead-center.
Scene 3 (2.6–3.65s): as "lokalbot dot com" is spoken, "lokalbot.com" wipes in left to right beneath the lockup with a teal leading edge, and a mono chip row fades up under it: "FREE · OPEN SOURCE · MACOS 15 · APPLE SILICON". End card holds dead static from ~3.2s — the final read.
