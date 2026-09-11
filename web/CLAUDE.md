# Website (`web/`)

Static site deployed to Vercel at https://www.lokalbot.com — no build step. `vercel.json` at the **repo root** (not in `web/`) points Vercel at `web/` (`outputDirectory`) with `cleanUrls: true`, so pages are served extensionless (`/lokalbot-vs-granola`). Canonicals, sitemap entries, and inter-page links must use those extensionless URLs; do not make crawlers follow `.html` redirects. Preview through a local HTTP server rather than `file://`. Design system lives in `styles.css` (glass panels via `--glass-*` CSS vars, `.reveal` scroll animations); `app.js` is dependency-free and null-safe so any page can include it. New surface styles should be added to both the `prefers-reduced-transparency` and no-`backdrop-filter` fallback lists.

The homepage is self-contained in `index.html`, `landing.css`, and `landing.js`.
Shared guide/comparison pages retain `styles.css` and `app.js`; do not load both
interaction scripts on the homepage. Comparison and guide HTML is generated:
edit `Scripts/*.template.html` and `Scripts/*_pages.py`, then run
`python3 Scripts/render_web.py`. Set a guide's `updated` date when content changes.

Position LokalBot as general work memory: Remember, Recall, Write, and Act.
Meetings are one input alongside saved moments and selected workday context.
The approved homepage uses the oversized wordmark, charcoal surfaces, mint
accents, and “A memory for all your work.” Keep that composition and copy.
Colors follow the native WorkspacePalette dark roles and Brand.tealBright.

The gallery uses existing app screenshots, encoded without changing their
content or dimensions. From the repository root, regenerate them with:

```sh
cwebp -q 82 -m 6 -sharp_yuv Assets/screenshots/timeline.png -o web/assets/screens/timeline-workspace.webp
cwebp -q 82 -m 6 -sharp_yuv Assets/screenshots/quick-recall.png -o web/assets/screens/quick-recall.webp
cwebp -q 82 -m 6 -sharp_yuv Assets/screenshots/cotyping.png -o web/assets/screens/cotyping.webp
```

Gallery links must work without JavaScript. Recall uses an explicitly
illustrative, in-browser library: keep search text local and insert it through
textContent, never HTML. Failed scripts leave a static app-image link available.
Source and image dialogs use native modal focus/Escape behavior. Maintain the
legacy homepage fragment targets for shared guide links and existing inbound URLs.

Public capture-default claims describe the downloadable stable release, currently v0.7.2, rather than unreleased `master`. The release maintainer must check the tagged settings source and update the homepage FAQ, privacy page, and affected guide data together when publishing a new stable release. Keep defaults distinct from macOS permissions and preferences retained during upgrades. Primary download links use the stable `releases/latest/download/LokalBot.dmg` asset; keep release notes and installation help separately available.

Website browser checks run in the hosted Website workflow. Do not run automated UI tests locally on this MacBook. Local static checks and manual browser inspection are supported.
