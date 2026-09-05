# Website (`web/`)

Static site deployed to Vercel at https://www.lokalbot.com — no build step. `vercel.json` at the **repo root** (not in `web/`) points Vercel at `web/` (`outputDirectory`) with `cleanUrls: true`, so pages are served extensionless (`/lokalbot-vs-granola`). Canonicals, sitemap entries, and inter-page links must use those extensionless URLs; do not make crawlers follow `.html` redirects. Preview through a local HTTP server rather than `file://`. Design system lives in `styles.css` (glass panels via `--glass-*` CSS vars, `.reveal` scroll animations); `app.js` is dependency-free and null-safe so any page can include it. New surface styles should be added to both the `prefers-reduced-transparency` and no-`backdrop-filter` fallback lists.

Homepage composition is scoped in `landing.css`. Comparison and guide HTML is generated: edit `Scripts/*.template.html` and `Scripts/*_pages.py`, then run `python3 Scripts/render_web.py`. Set a guide's `updated` date when its content changes.

Position LokalBot as general work memory: Remember, Recall, Write, and Act. Meetings are one input alongside saved moments and selected workday context. Use Today and Quick Recall to show that breadth; keep the full day and writing/action capabilities central to the story.

The hero uses a WebP encoding of the existing Today screenshot. Regenerate it with `cwebp -q 82 -m 6 -sharp_yuv web/assets/screens/today.jpg -o web/assets/screens/today.webp` from the repo root. Quick Recall is encoded the same way from `Assets/screenshots/quick-recall.png` into `web/assets/screens/quick-recall.webp`. Keep the original Today JPEG as the full-screenshot link. The video waits until it enters the viewport to preload metadata, and playback always requires a user gesture.

Public capture-default claims describe the downloadable stable release, currently v0.7.2, rather than unreleased `master`. The release maintainer must check the tagged settings source and update the homepage FAQ, privacy page, and affected guide data together when publishing a new stable release. Keep defaults distinct from macOS permissions and preferences retained during upgrades. Primary download links use the stable `releases/latest/download/LokalBot.dmg` asset; keep release notes and installation help separately available.

Website browser checks run in the hosted Website workflow. Do not run automated UI tests locally on this MacBook. Local static checks and manual browser inspection are supported.
