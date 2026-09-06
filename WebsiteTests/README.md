# Website checks

The Website workflow runs Chromium checks on GitHub's Ubuntu runner for homepage
and shared-page layouts, installer links, app-gallery image loading and race/failure
handling, example recall search and source dialogs, keyboard navigation, network
disclosure, no-JavaScript/blocked-script fallback, and reduced motion.
The 640 × 360 case checks the CSS reflow equivalent of a 1280 × 720 viewport at
200% zoom; it is not a physical-device or assistive-technology certification.

Each PR run compares the base commit and PR on the same runner, retaining
before/after screenshots, failure traces, and three cold-load performance samples.
The job summary reports median LCP, CLS, completed transfer, resource count, and
page height. These are synthetic diagnostics, not conversion or field metrics.

Run browser checks on hosted/remote runners, never locally on this MacBook.
For local static checks, use `python3 Scripts/render_web.py --check` and
`node --check web/landing.js` from the repo root. For manual inspection, use
`python3 Scripts/serve-web.py 8793` and open http://127.0.0.1:8793/.

Before publishing a release, verify the stable installer URL resolves to the
expected DMG and update release-specific copy as described in `web/CLAUDE.md`.
Usability sessions, full screen-reader review, physical-device checks, and fresh
released-app installation/privacy tests remain separate validation work.
