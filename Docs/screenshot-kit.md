# Screenshot kit — Show HN + website

The shot list and repeatable setup for marketing screenshots. Shots are taken
against the **LokalBot UI Test Host** target with a synthetic library, so no
real meetings, TCC grants, or network are involved and the content is
reproducible.

## Setup

1. Build the host once: the `LokalBot UI Test Host` scheme (or let
   `Scripts/ui-tests.sh` build it).
2. Plant a synthetic library. The UI-test fixture
   (`LokalBotUITests/SyntheticFixture.swift`) is the reference for what a
   good-looking library contains: a few meetings across two days with
   transcripts + summaries, and activity blocks so Capture opens in Day scope.
3. Launch the host with the capture environment (see
   `applyCaptureEnvironment` in `LokalBot/AppLifecycle.swift`):

```bash
LOKALBOT_UI_TEST=1 \
LOKALBOT_STORAGE_ROOT=/tmp/lokalbot-shots \
LOKALBOT_DISMISS_ONBOARDING=1 \
LOKALBOT_INITIAL_SECTION=capture \
LOKALBOT_SELECT_FIRST=1 \
"…/LokalBot UI Test Host.app/Contents/MacOS/LokalBot"
```

`LOKALBOT_INITIAL_SECTION` accepts `capture`, `ask`, `type`, `settings`, and
the legacy names — `models` lands on Settings with the Models tab
preselected (spec §2.5).

## Conventions

- **Appearance:** dark mode is the primary set (matches the site's slate
  aesthetic and the app icon); repeat the hero shot in light mode for the
  README.
- **Window:** ~1280×800, Retina (2×) display, `⇧⌘4 + space` window capture
  with shadow.
- **Content:** synthetic names only — no real meeting titles, contacts, or
  screen content.

## Shot list

| # | Shot | Setup | Used in |
|---|------|-------|---------|
| 1 | Menu-bar dropdown while recording (HeroPanel, live timer + waveform) | Start a manual recording in the host, click the status item | Website hero strip, Show HN comment |
| 2 | Capture — Day view (track + day overview) | `LOKALBOT_INITIAL_SECTION=capture`, fixture with activity | Website "Capture" section, README |
| 3 | Capture — Library + meeting inspector | `capture` + `LOKALBOT_SELECT_FIRST=1`, switch scope to Library | Website, README |
| 4 | Ask — results with facets + escalated assistant answer | `LOKALBOT_INITIAL_SECTION=ask`, type a query, press ↵ | Website "Ask" section, Show HN |
| 5 | Type — Cotyping ghost text in a real app | Real (Dev) build, TextEdit + ghost suggestion visible | Website "Type" section |
| 6 | Settings — Models tab (role cards) | `LOKALBOT_INITIAL_SECTION=models` | README, docs |

Shot 5 is the one shot that needs the real Dev build (ghost text requires the
AX/event-tap path the host build skips); grant the Dev bundle its own
Accessibility/Input Monitoring permissions.

## Destinations

- `web/` — hero + per-pillar sections (`index.html`), comparison pages.
- `Docs/show-hn-kit.md` — the Show HN post references shots 1, 2, and 4.
- `README.md` — hero (light + dark) and shots 2/3/6.
