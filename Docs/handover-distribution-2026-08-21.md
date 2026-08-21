# Handover: distribution launch tasks (for Codex)

_Date: 2026-08-21. Author session produced all artifacts below; they are staged, not committed._
_Repo: `stevyhacker/lokalbot`. Machine has: `gh` authed as **stevyhacker** (scopes include `repo`, SSH git protocol), `claude` CLI, `hf` CLI (**unauthenticated**), Raycast.app installed._

## State you inherit

| Artifact | Path | Status |
| --- | --- | --- |
| Cask v0.6.2 (sha256 verified) + tap guide | `Distribution/homebrew/` | staged |
| Raycast extension (tsc clean) | `Distribution/raycast/` | staged |
| Claude Code plugin manifests + `/recall` | `.claude-plugin/`, `Distribution/claude-plugin/` | staged |
| HF collection/Space specs + benchmark data | `Distribution/huggingface/` | staged |
| Submission copy (Uneed/Console/DevHunt/registries) | `Docs/distribution-submissions-2026-08.md` | staged |

**Prerequisite for tasks 2–3:** commit and push the staged set to `master`
(suggested message: `Add distribution artifacts: Homebrew cask, Raycast extension, Claude Code plugin, HF kit, submission docs`).
Do not push until the owner confirms, unless this handover is your authorization.

---

## Task 1 — Own tap (do first; guaranteed win)

1. `gh repo create stevyhacker/homebrew-tap --public --clone /tmp/homebrew-tap` (add a one-line README: "Homebrew tap for LokalBot").
2. Copy `Distribution/homebrew/lokalbot.rb` to `/tmp/homebrew-tap/Casks/lokalbot.rb`. Commit message: `Add lokalbot 0.6.2`. Push to `main`.
3. Verify read-only: `brew tap stevyhacker/tap && brew info --cask lokalbot` must show version 0.6.2 and the correct sha256. Do NOT `brew install` on this machine without asking.

**Acceptance:** `brew info --cask lokalbot` resolves from the tap; repo public.

## Task 2 — Upstream homebrew-cask PR

1. Read <https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/CONTRIBUTING.md> for the current new-cask commit-message convention before committing.
2. `gh repo fork Homebrew/homebrew-cask --clone /tmp/hbc`; add file at `Casks/l/lokalbot.rb` (copy of our cask, byte-identical apart from nothing — keep identical).
3. In `/tmp/hbc`: `brew audit --strict --new-cask Casks/l/lokalbot.rb` and `brew style --fix Casks/l/lokalbot.rb`. Fix everything audit reports. Known machine limitation: Xcode 26.6 < required 27.0 blocks the full audit — record that in the PR body rather than skipping silently.
4. Commit per convention, push to fork, `gh pr create -R Homebrew/homebrew-cask` with title `lokalbot (new cask)` plus: what it is, source URL, signed/notarized note, `brew audit` result incl. the Xcode caveat.
5. If a maintainer challenges notability (30 stars): reply politely linking lokalbot.com, the signed/notarized releases, and the own-tap existence; do not argue.

**Acceptance:** PR open with CI green (or documented Xcode caveat); no force-pushes after review starts.

## Task 3 — Claude Code plugin: verify, then list

1. After the push (prerequisite): in a scratch dir run `claude` and execute `/plugin marketplace add stevyhacker/lokalbot` then `/plugin install lokalbot@lokalbot`. Confirm `/recall` appears.
2. Headless MCP check without Claude: `printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}\n' | lokalbot-cli mcp | head -c 400` must return a server init response.
3. Submit the community directory form <https://clau.de/plugin-directory-submission> using the text in `Docs/distribution-submissions-2026-08.md` §4b. If the form needs an interactive browser login you cannot complete, stop and flag for the owner.

**Acceptance:** plugin installs from the public repo; form submitted or explicitly handed back.

## Task 4 — Launch platforms (mostly pre-filled)

Copy lives in `Docs/distribution-submissions-2026-08.md`. Field-by-field.

- **Console.dev:** send the pitch email to hello@console.dev Mon/Tue for the Thursday newsletter. If you have no mail access, save the final draft to `Docs/outbox/console-dev-pitch.md` and flag.
- **Uneed.best / DevHunt:** both need interactive logins. Pre-check the live forms still match the kit's field lists; update the kit if fields changed; then hand off to the owner for the actual submission clicks.
- Timing note from the kit: stack Uneed/DevHunt on the same day as the Show HN post (star velocity feeds GitHub Trending); Reddit drips after.

**Acceptance:** kit re-verified against live forms; email drafted; submissions either done or explicitly owner-gated.

## Task 5 — Hugging Face (blocked on one credential)

Blocker: `hf` is unauthenticated and `.env` has no HF token. Ask the owner to run `hf auth login` once.

Then:
1. Write `Distribution/huggingface/scripts/create_collection.py` using `huggingface_hub`: creates collection "LokalBot recommended local stack" with the six API-verified repos listed in `Distribution/huggingface/COLLECTION.md` and the description paragraph from that file.
2. Create the Space per `Distribution/huggingface/SPACE-benchmark.md` (sdk: static): Space README.yaml frontmatter included there; body generated from `benchmark-summary.md`.
3. Run both, capture the resulting URLs, and append them to `Distribution/huggingface/README.md`.

**Acceptance:** collection + Space live; URLs recorded; zero third-party weights uploaded.

## Task 6 — Raycast extension

1. `cd Distribution/raycast && npm install && npm run build` — fix anything `ray build` reports (tsc already clean).
2. Store publish (`npm run publish`) requires the owner's Raycast account session in Raycast.app — prepare everything, then hand the single command to the owner.

**Acceptance:** `ray build` succeeds; publish command ready.

---

## Ground rules

- Never modify files outside the paths named above; never rehost third-party model weights.
- All product claims come from the fact whitelist at the top of `Docs/distribution-submissions-2026-08.md` — no invented metrics anywhere.
- Anything requiring a password, 2FA, or an interactive OAuth consent: stop and flag instead of improvising.
