#!/usr/bin/env python3
"""Render the web/lokalbot-vs-*.html comparison pages from one template.

The four comparison pages share their head, nav, CTA, and footer markup;
only the competitor-specific content differs. That shared markup lives in
Scripts/compare.template.html and the per-competitor content lives in
Scripts/comparison_pages.py. This script combines them and writes the
finished HTML into web/, which stays checked in — hosting is still fully
static and nothing runs at deploy time.

To change a page:
1. edit Scripts/comparison_pages.py (content) or compare.template.html (markup)
2. run `python3 Scripts/render_web.py`
3. commit the regenerated web/lokalbot-vs-*.html files

Usage:
    python3 Scripts/render_web.py            # render into web/
    python3 Scripts/render_web.py --check    # verify web/ is up to date (CI)
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comparison_pages import PAGES  # noqa: E402

TOKEN_OPEN = "{{"

CHECK_ICON = '<i class="ph ph-check" aria-hidden="true"></i>'


def repo_root() -> Path:
    """Repo root, derived from this script's location under Scripts/."""

    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render LokalBot's comparison pages.")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the checked-in HTML matches the template + data without writing.",
    )
    return parser.parse_args()


def render_table_rows(rows: list[tuple[str, str, str]]) -> str:
    parts = []
    for feature, lokal, competitor in rows:
        parts.append(
            "            <tr>\n"
            f'              <th scope="row">{feature}</th>\n'
            f"              <td>{lokal}</td>\n"
            f"              <td>{competitor}</td>\n"
            "            </tr>"
        )
    return "\n".join(parts)


def render_pick_items(items: list[str]) -> str:
    return "\n".join(f"            <li>{CHECK_ICON} {item}</li>" for item in items)


def render_faq_items(entries: list[tuple[str, str]]) -> str:
    parts = []
    for question, answer in entries:
        parts.append(
            '        <details class="qa">\n'
            f'          <summary>{question}<i class="ph ph-plus" aria-hidden="true"></i></summary>\n'
            f"          <p>{answer}</p>\n"
            "        </details>"
        )
    return "\n".join(parts)


def render_more_links(page: dict) -> str:
    """Links to every other comparison page, in PAGES order."""

    return "\n".join(
        f'        <a href="{other["slug"]}.html">{other["h1"]}</a>'
        for other in PAGES
        if other["slug"] != page["slug"]
    )


def render_page(template: str, page: dict) -> str:
    replacements = {
        "{{SLUG}}": page["slug"],
        "{{TITLE}}": page["title"],
        "{{META_DESCRIPTION}}": page["description"],
        "{{OG_TITLE}}": page["og_title"],
        "{{OG_DESCRIPTION}}": page["og_description"],
        "{{H1}}": page["h1"],
        "{{LEAD}}": page["lead"],
        "{{COMPETITOR_COLUMN}}": page["competitor_column"],
        "{{TABLE_ROWS}}": render_table_rows(page["table_rows"]),
        "{{COMPETITOR_PICK_TITLE}}": page["competitor_pick_title"],
        "{{COMPETITOR_PICK_SUB}}": page["competitor_pick_sub"],
        "{{COMPETITOR_PICK_ITEMS}}": render_pick_items(page["competitor_pick_items"]),
        "{{LOKAL_PICK_SUB}}": page["lokal_pick_sub"],
        "{{LOKAL_PICK_ITEMS}}": render_pick_items(page["lokal_pick_items"]),
        "{{FAQ_ITEMS}}": render_faq_items(page["faq"]),
        "{{CTA_TITLE}}": page["cta_title"],
        "{{MORE_LINKS}}": render_more_links(page),
        "{{DISCLAIMER}}": page["disclaimer"],
    }
    rendered = template
    for token, value in replacements.items():
        if token not in rendered:
            raise SystemExit(f"Template is missing the {token} placeholder.")
        rendered = rendered.replace(token, value)
    if TOKEN_OPEN in rendered:
        line = next(l for l in rendered.splitlines() if TOKEN_OPEN in l)
        raise SystemExit(f"Unreplaced placeholder in rendered output: {line.strip()}")
    return rendered


def main() -> int:
    args = parse_args()

    template_path = repo_root() / "Scripts" / "compare.template.html"
    if not template_path.is_file():
        raise SystemExit(f"Template does not exist: {template_path}")
    template = template_path.read_text(encoding="utf-8")

    web_dir = repo_root() / "web"
    if not web_dir.is_dir():
        raise SystemExit(f"Output directory does not exist: {web_dir}")

    stale = []
    for page in PAGES:
        output_path = web_dir / f"{page['slug']}.html"
        rendered = render_page(template, page)
        if args.check:
            on_disk = output_path.read_text(encoding="utf-8") if output_path.is_file() else None
            if on_disk != rendered:
                stale.append(output_path)
            continue
        output_path.write_text(rendered, encoding="utf-8")
        print(f"Rendered {output_path.relative_to(repo_root())}")

    if stale:
        names = ", ".join(str(p.relative_to(repo_root())) for p in stale)
        raise SystemExit(
            f"Out of date: {names}. Run `python3 Scripts/render_web.py` and commit."
        )
    if args.check:
        print(f"All {len(PAGES)} comparison pages are up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
