#!/usr/bin/env python3
"""Turn ElevenLabs character alignment into deterministic burned-in captions."""

from __future__ import annotations

import html
import json
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent
TIMING_PATH = PROJECT_DIR / "assets" / "narration-elevenlabs-timing.json"
OUTPUT_PATH = PROJECT_DIR / "captions.generated.js"

PHRASES = [
    "Your Mac sees everything you work on—and forgets it.",
    "LokalBot turns your workday into a private AI memory,",
    "entirely on your Mac.",
    "It records both sides of calls without joining as a bot,",
    "then creates recaps with decisions, next steps,",
    "and speaker-labeled evidence.",
    "Press Control-Option-Space for Quick Recall.",
    "Search meetings and saved screen moments,",
    "then jump straight to the source.",
    "In Timeline, Context Rewind lets you scrub, play,",
    "and bookmark the parts of your day you chose to keep.",
    "For Dictation, hold Option-Space,",
    "speak naturally, and release.",
    "LokalBot transcribes locally,",
    "then inserts the result at your cursor.",
    "Cotyping adds on-device ghost-text autocomplete",
    "in almost any app.",
    "Press Tab to accept.",
    "Ask your day for an answer with citations.",
    "No account. No telemetry.",
    "LokalBot: your private AI memory for work.",
]

HIGHLIGHTS = [
    "Quick Recall",
    "Context Rewind",
    "Dictation",
    "Cotyping",
    "Tab",
    "private AI memory",
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
                "end": round(ends[end_index] + 0.09, 3),
                "html": styled(phrase),
            }
        )
        search_from = end_index + 1

    OUTPUT_PATH.write_text(
        "window.LOKALBOT_CAPTIONS = "
        + json.dumps(captions, ensure_ascii=False, indent=2)
        + ";\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
