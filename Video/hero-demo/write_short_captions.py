#!/usr/bin/env python3
"""Build the deterministic caption rail for the 30-second showcase cut."""

from __future__ import annotations

import html
import json
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent
TIMING_PATH = PROJECT_DIR / "assets" / "narration-short-timing.json"
OUTPUT_PATH = PROJECT_DIR / "captions-short.generated.js"

PHRASES = [
    "Turn your workday into a private AI memory,",
    "entirely on your Mac.",
    "Quick Recall searches meetings",
    "and saved screen moments.",
    "Context Rewind lets you scrub, play,",
    "and bookmark your day.",
    "Dictate into any app with Option-Space.",
    "Cotyping adds on-device ghost text—",
    "press Tab to accept.",
    "No account. No telemetry.",
    "LokalBot: your private AI memory for work.",
]

HIGHLIGHTS = [
    "private AI memory",
    "Quick Recall",
    "Context Rewind",
    "Option-Space",
    "Cotyping",
    "Tab",
]


def styled(phrase: str) -> str:
    rendered = html.escape(phrase)
    for highlight in HIGHLIGHTS:
        escaped = html.escape(highlight)
        rendered = rendered.replace(escaped, f"<em>{escaped}</em>")
    return rendered.replace(" ", "&nbsp;")


def main() -> None:
    timing = json.loads(TIMING_PATH.read_text(encoding="utf-8"))
    alignment = timing["production_alignment"]
    characters = alignment["characters"]
    starts = alignment["character_start_times_seconds"]
    ends = alignment["character_end_times_seconds"]
    transcript = "".join(characters)

    captions = []
    search_from = 0
    for phrase in PHRASES:
        start_index = transcript.index(phrase, search_from)
        end_index = start_index + len(phrase) - 1
        captions.append(
            {
                "start": round(max(0.0, starts[start_index] - 0.03), 3),
                "end": round(ends[end_index] + 0.08, 3),
                "html": styled(phrase),
            }
        )
        search_from = end_index + 1

    for index in range(len(captions) - 1):
        captions[index]["end"] = round(
            min(captions[index]["end"], captions[index + 1]["start"] - 0.01),
            3,
        )

    OUTPUT_PATH.write_text(
        "window.LOKALBOT_SHORT_CAPTIONS = "
        + json.dumps(captions, ensure_ascii=False, indent=2)
        + ";\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
