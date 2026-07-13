#!/usr/bin/env python3
"""Render LokalBot's comparison pages, guides, and sitemap.

Generated HTML stays checked in under web/. Hosting remains fully static and
nothing runs at deploy time.

To change a page:
1. edit the relevant *_pages.py content or *.template.html markup
2. run `python3 Scripts/render_web.py`
3. commit the regenerated files under web/

Usage:
    python3 Scripts/render_web.py            # render into web/
    python3 Scripts/render_web.py --check    # verify web/ is up to date (CI)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comparison_pages import PAGES  # noqa: E402
from guide_pages import GUIDES  # noqa: E402

TOKEN_OPEN = "{{"

CHECK_ICON = '<i class="ph ph-check" aria-hidden="true"></i>'


def repo_root() -> Path:
    """Repo root, derived from this script's location under Scripts/."""

    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render LokalBot's static SEO pages.")
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
        f'        <a href="{other["slug"]}">{other["h1"]}</a>'
        for other in PAGES
        if other["slug"] != page["slug"]
    )


def guide_by_slug(slug: str) -> dict:
    try:
        return next(guide for guide in GUIDES if guide["slug"] == slug)
    except StopIteration as error:
        raise SystemExit(f"Unknown related guide slug: {slug}") from error


def render_related_links(page: dict) -> str:
    cards = []
    for slug in page["related"]:
        related = guide_by_slug(slug)
        cards.append(
            f'        <a class="guide-card" href="{related["slug"]}">\n'
            f'          <span class="guide-card__eyebrow">{related["eyebrow"]}</span>\n'
            f'          <strong>{related["h1"]}</strong>\n'
            f'          <span>{related["description"]}</span>\n'
            '        </a>'
        )
    return "\n".join(cards)


def render_guide_cards() -> str:
    return "\n".join(
        f'      <a class="guide-card" href="{guide["slug"]}">\n'
        f'        <span class="guide-card__eyebrow">{guide["eyebrow"]}</span>\n'
        f'        <strong>{guide["h1"]}</strong>\n'
        f'        <span>{guide["description"]}</span>\n'
        f'        <span class="guide-card__meta">{guide["read_time"]}</span>\n'
        '      </a>'
        for guide in GUIDES
    )


def guide_structured_data(page: dict) -> str:
    url = f'https://www.lokalbot.com/{page["slug"]}'
    graph = {
        "@context": "https://schema.org",
        "@graph": [
            {
                "@type": "Article",
                "headline": page["h1"],
                "description": page["description"],
                "datePublished": "2026-07-13",
                "dateModified": "2026-07-13",
                "mainEntityOfPage": url,
                "image": "https://www.lokalbot.com/assets/og-image.png",
                "author": {
                    "@type": "Organization",
                    "name": "LokalBot project",
                    "url": "https://www.lokalbot.com/",
                },
                "publisher": {
                    "@type": "Organization",
                    "name": "LokalBot project",
                    "url": "https://www.lokalbot.com/",
                },
            },
            {
                "@type": "BreadcrumbList",
                "itemListElement": [
                    {"@type": "ListItem", "position": 1, "name": "Home", "item": "https://www.lokalbot.com/"},
                    {"@type": "ListItem", "position": 2, "name": "Guides", "item": "https://www.lokalbot.com/guides"},
                    {"@type": "ListItem", "position": 3, "name": page["h1"], "item": url},
                ],
            },
            {
                "@type": "FAQPage",
                "mainEntity": [
                    {
                        "@type": "Question",
                        "name": question,
                        "acceptedAnswer": {"@type": "Answer", "text": answer},
                    }
                    for question, answer in page["faq"]
                ],
            },
        ],
    }
    return json.dumps(graph, ensure_ascii=False, separators=(",", ":"))


def render_guide_page(template: str, page: dict) -> str:
    replacements = {
        "{{SLUG}}": page["slug"],
        "{{TITLE}}": page["title"],
        "{{META_DESCRIPTION}}": page["description"],
        "{{EYEBROW}}": page["eyebrow"],
        "{{H1}}": page["h1"],
        "{{LEAD}}": page["lead"],
        "{{READ_TIME}}": page["read_time"],
        "{{BODY}}": page["body"].strip(),
        "{{FAQ_ITEMS}}": render_faq_items(page["faq"]),
        "{{RELATED_LINKS}}": render_related_links(page),
        "{{STRUCTURED_DATA}}": guide_structured_data(page),
    }
    rendered = template
    for token, value in replacements.items():
        if token not in rendered:
            raise SystemExit(f"Guide template is missing the {token} placeholder.")
        rendered = rendered.replace(token, value)
    if TOKEN_OPEN in rendered:
        line = next(line for line in rendered.splitlines() if TOKEN_OPEN in line)
        raise SystemExit(f"Unreplaced placeholder in guide output: {line.strip()}")
    return rendered


def render_guides_index(template: str) -> str:
    token = "{{GUIDE_CARDS}}"
    if token not in template:
        raise SystemExit(f"Guides template is missing the {token} placeholder.")
    rendered = template.replace(token, render_guide_cards())
    if TOKEN_OPEN in rendered:
        line = next(line for line in rendered.splitlines() if TOKEN_OPEN in line)
        raise SystemExit(f"Unreplaced placeholder in guides output: {line.strip()}")
    return rendered


def render_sitemap() -> str:
    paths = [
        "",
        "guides",
        *(guide["slug"] for guide in GUIDES),
        "privacy",
        "terms",
        "support",
        *(page["slug"] for page in PAGES),
    ]
    entries = []
    for path in paths:
        url = f"https://www.lokalbot.com/{path}"
        entries.append(
            "  <url>\n"
            f"    <loc>{url}</loc>\n"
            "    <lastmod>2026-07-13</lastmod>\n"
            "  </url>"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(entries)
        + "\n</urlset>\n"
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

    scripts_dir = repo_root() / "Scripts"
    template_paths = {
        "compare": scripts_dir / "compare.template.html",
        "guide": scripts_dir / "guide.template.html",
        "guides": scripts_dir / "guides.template.html",
    }
    for template_path in template_paths.values():
        if not template_path.is_file():
            raise SystemExit(f"Template does not exist: {template_path}")
    templates = {
        name: path.read_text(encoding="utf-8")
        for name, path in template_paths.items()
    }

    web_dir = repo_root() / "web"
    if not web_dir.is_dir():
        raise SystemExit(f"Output directory does not exist: {web_dir}")

    stale = []
    for page in PAGES:
        output_path = web_dir / f"{page['slug']}.html"
        rendered = render_page(templates["compare"], page)
        if args.check:
            on_disk = output_path.read_text(encoding="utf-8") if output_path.is_file() else None
            if on_disk != rendered:
                stale.append(output_path)
            continue
        output_path.write_text(rendered, encoding="utf-8")
        print(f"Rendered {output_path.relative_to(repo_root())}")

    generated_pages = [
        (web_dir / f"{guide['slug']}.html", render_guide_page(templates["guide"], guide))
        for guide in GUIDES
    ]
    generated_pages.extend(
        [
            (web_dir / "guides.html", render_guides_index(templates["guides"])),
            (web_dir / "sitemap.xml", render_sitemap()),
        ]
    )
    for output_path, rendered in generated_pages:
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
        count = len(PAGES) + len(GUIDES) + 2
        print(f"All {count} generated web files are up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
