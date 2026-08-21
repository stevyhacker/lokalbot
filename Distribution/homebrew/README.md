# Homebrew distribution for LokalBot

This directory contains the Homebrew cask for [LokalBot](https://www.lokalbot.com)
(`lokalbot.rb`) and notes on validating it and shipping it to users.

- Cask token: `lokalbot`
- Current version packaged here: **0.6.2**
- Requirements enforced by the cask: Apple Silicon (M1+), macOS 15.0+
- Style verified against `Homebrew/homebrew-cask` `CONTRIBUTING.md`, the
  [Cask Cookbook stanza order](https://docs.brew.sh/Cask-Cookbook#stanza-order),
  and the livecheck GitHub strategies in `Homebrew/brew`.

## 1. Validate locally

Homebrew resolves casks through tap structure, so `brew style` / `brew info` /
`brew audit` will **not** accept a bare file path like
`./Distribution/homebrew/lokalbot.rb`. Put the cask in a throwaway local tap
first (this is exactly what we ran; it is safe to delete afterwards):

```sh
ruby -c Distribution/homebrew/lokalbot.rb          # Syntax OK

brew tap-new --no-git local/scratch
mkdir -p "$(brew --repository)/Library/Taps/local/homebrew-scratch/Casks"
cp Distribution/homebrew/lokalbot.rb \
   "$(brew --repository)/Library/Taps/local/homebrew-scratch/Casks/"

brew style --cask local/scratch/lokalbot           # style gate
brew info --cask local/scratch/lokalbot            # parses + prints metadata
brew audit --cask local/scratch/lokalbot --online  # full audit (downloads DMG)
```

Expected results:

| Command | Expected |
| --- | --- |
| `ruby -c …` | `Syntax OK` |
| `brew style …` | `1 file inspected, no offenses detected` |
| `brew info …` | shows `lokalbot (LokalBot): 0.6.2 (auto_updates)`, the desc, and `Required: arm64 architecture, macOS >= 15` |
| `brew audit …` | exits 0 silently (downloads the ~55 MB DMG, verifies sha256, checks signing) |

Verified on this machine: `ruby -c`, `brew style`, `brew info`, and
`brew livecheck local/scratch/lokalbot` (`0.6.2 ==> 0.6.2`, proving the
`:github_releases` strategy resolves the version). The full audit was blocked
by an environment issue — Homebrew's signature-verification step requires a
newer Xcode than installed ("Your Xcode (26.6) is too outdated") — so the
sha256 was verified manually instead:

```sh
curl -sLO https://github.com/stevyhacker/lokalbot/releases/download/v0.6.2/LokalBot.dmg
shasum -a 256 LokalBot.dmg
# 17817f2cae9beb5c14a43aedad98bd6d51c9985261414791e73c1b30df173842
```

Clean up the scratch tap when done:

```sh
rm -rf "$(brew --repository)/Library/Taps/local/homebrew-scratch"
brew untap local/scratch 2>/dev/null || true
```

## 2. Submit upstream to Homebrew/homebrew-cask

Per [CONTRIBUTING.md](https://github.com/Homebrew/homebrew-cask/blob/HEAD/CONTRIBUTING.md):
one PR per cask, two-space indent, no extraneous comments (the privacy note in
our zap block is allowed only if reviewers accept it — be ready to trim it),
and **AI-assisted PRs must be disclosed** in the opening comment (name the
tool/model used), must not carry an AI `Co-authored-by`/`Assisted-by` trailer,
and you may have only one open at a time. You answer all maintainer questions
yourself.

Steps:

1. Fork https://github.com/Homebrew/homebrew-cask and clone your fork.
2. Add the file at exactly `Casks/l/lokalbot.rb` (one-letter subdirectory by
   first character of the token) on a branch named after the change.
3. Commit message for a new cask follows the `"<token> <version>"` pattern
   from CONTRIBUTING (`ie. transmission 2.82`):

   ```sh
   git add Casks/l/lokalbot.rb
   git commit -m "lokalbot 0.6.2"
   ```

4. Open the PR against `Homebrew/homebrew-cask` → `master`. PR body template
   (GitHub inserts most of this via the PR template — keep those checklist
   items and add):

   ```markdown
   Create lokalbot 0.6.2 (new cask)

   - Website: https://www.lokalbot.com
   - Repo (source): https://github.com/stevyhacker/lokalbot
   - DMG is Developer ID signed, notarized, stapled; updates via Sparkle
     (appcast attached to each release).
   - `brew audit --cask` and `brew style --cask` pass locally.
   - Disclosure: this cask was drafted with an LLM assistant (<tool/model>); I
     reviewed every line.
   ```

5. CI runs `brew test --cask lokalbot` (installs, launches, uninstalls on all
   supported macOS runners). It must be green before review proceeds. Watch it
   from your machine with:

   ```sh
   brew test --cask lokalbot   # after merging locally, or rely on CI
   ```

### Realistic risk: notability

`homebrew/cask` applies an acceptance bar and routinely challenges or closes
PRs for apps without meaningful adoption (a ~30-star repo will draw the
question). Prepare one paragraph up front pointing at concrete traction
(downloads, users, coverage) and link it in the PR body. If maintainers close
it as not notable, do not relitigate — use the tap fallback below. The cask
file itself needs zero changes to live there.

## 3. Fallback: own tap

If upstream declines, ship via `stevyhacker/homebrew-tap`. Repo layout is
minimal — just the cask at the root of the default branch:

```
homebrew-tap/
└── Casks/
    └── lokalbot.rb      # same file as Distribution/homebrew/lokalbot.rb
```

No `tap_migrations.json`, no formulae needed. Copy-paste install for users:

```sh
brew tap stevyhacker/tap https://github.com/stevyhacker/homebrew-tap
brew install --cask lokalbot
```

(Once the tap exists under your account, the short form
`brew tap stevyhacker/tap` also works.)

Bump routine for future releases:

1. New release is cut on GitHub (tag `vX.Y.Z`, asset `LokalBot.dmg`).
2. Compute the new sha256 of the DMG: `shasum -a 256 LokalBot.dmg`.
3. In `Casks/l/lokalbot.rb`, update `version` and `sha256`. Nothing else
   changes — the URL already interpolates `v#{version}`.
4. Livecheck keeps working across both distributions: the app's Sparkle
   `appcast.xml` is attached to every GitHub release, and the cask's
   `strategy :github_releases` reads the repo's releases API directly, so
   `brew livecheck lokalbot` sees new versions immediately.
5. Upstream path: if the cask was accepted, run
   `brew bump --open-pr lokalbot`; tap path: commit as `"lokalbot X.Y.Z"` and
   push to `main`.
