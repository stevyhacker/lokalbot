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

brew style --cask local/scratch/lokalbot       # style gate
brew info --cask local/scratch/lokalbot        # parses + prints metadata
brew livecheck local/scratch/lokalbot          # release discovery
brew audit --new --cask local/scratch/lokalbot # strict online new-cask audit
```

Expected results:

| Command | Expected |
| --- | --- |
| `ruby -c …` | `Syntax OK` |
| `brew style …` | `1 file inspected, no offenses detected` |
| `brew info …` | shows `lokalbot (LokalBot): 0.6.2 (auto_updates)`, the desc, and `Required: arm64 architecture, macOS >= 15` |
| `brew livecheck …` | shows `0.6.2 ==> 0.6.2` |
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
brew untap local/scratch
```

## 2. Submit upstream to Homebrew/homebrew-cask

Follow both [CONTRIBUTING.md](https://github.com/Homebrew/homebrew-cask/blob/HEAD/CONTRIBUTING.md)
and the maintained [pull-request guide](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request#cask-related-pull-request).
The important constraints are one PR per cask, two-space indentation, no
extraneous comments, and a disclosure in the opening comment naming any
AI/LLM tool and model used. Do not add AI attribution trailers, and answer all
maintainer questions yourself.

Steps:

1. Fork `Homebrew/homebrew-cask`, run `brew tap --force homebrew/cask`, and add
   the fork as a pushable remote in `$(brew --repository homebrew/cask)`.
2. Create a branch from the current `origin/HEAD`, then add the file at exactly
   `Casks/l/lokalbot.rb` (one-letter subdirectory by the cask token's first
   character).
3. With the owner's approval to install locally, run the current cask gates:

   ```sh
   HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask lokalbot
   brew uninstall --cask lokalbot
   brew audit --new --cask lokalbot
   brew style --fix --cask lokalbot
   brew lgtm --online
   ```

   If the installed Xcode blocks a local gate, record the exact output, but do
   not call the gate passed and do not treat the caveat as a substitute for
   green hosted CI.
4. Use the current new-cask commit convention:

   ```sh
   git add Casks/l/lokalbot.rb
   git commit -m "lokalbot 0.6.2 (new cask)"
   ```

5. Push the branch to the fork and open the PR against
   `Homebrew/homebrew-cask` → `main`. PR body template
   (GitHub inserts most of this via the PR template — keep those checklist
   items and add):

   ```markdown
   Create lokalbot 0.6.2 (new cask)

   - Website: https://www.lokalbot.com
   - Repo (source): https://github.com/stevyhacker/lokalbot
   - DMG is Developer ID signed, notarized, stapled; updates via Sparkle
     (appcast attached to each release).
   - Local validation: <list each command and its actual result; disclose any
     Xcode-blocked command as not run or blocked, never as passed>.
   - Disclosure: this cask was drafted with an LLM assistant (<tool/model>); I
     reviewed every line.
   ```

6. Hosted CI must be green before the PR is considered complete. A local Xcode
   limitation belongs in the PR body but does not excuse a failed hosted job.

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
3. In the upstream checkout update `Casks/l/lokalbot.rb`; in the own tap update
   `Casks/lokalbot.rb`. Change `version` and `sha256`; the URL already
   interpolates `v#{version}`.
4. Livecheck keeps working across both distributions: the app's Sparkle
   `appcast.xml` is attached to every GitHub release, and the cask's
   `strategy :github_releases` reads the repo's releases API directly, so
   `brew livecheck lokalbot` sees new versions immediately.
5. Upstream path: if the cask was accepted, run
   `brew bump --open-pr lokalbot`; tap path: commit as `"lokalbot X.Y.Z"` and
   push to `main`.
